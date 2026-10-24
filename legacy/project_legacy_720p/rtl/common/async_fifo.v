//=============================================================================
// async_fifo.v  —  双时钟异步 FIFO（格雷码指针）
//-----------------------------------------------------------------------------
// 用途：跨时钟域搬运"需要原子有序"的多比特数据流，例如：
//   - SD 字节流：sd_clk(25MHz) -> 系统 50MHz（供 FAT32 解析）
//   - 音频 PCM：系统域 -> 像素域（PWM 载波节拍）
//   - 频谱幅值：音频域 -> 像素域
//
// 结构：双口 RAM + 读写指针（二进制转格雷码后跨域两级同步 + 空满比较）。
// 约束：DEPTH 必须是 2 的幂；读侧高有效 rd_en，写侧 wr_en。
//=============================================================================
`timescale 1ns / 1ps

module async_fifo #(
    parameter DW    = 8,           // 数据位宽
    parameter DEPTH = 512          // FIFO 深度，必须为 2 的幂，至少为 4
)(
    // 写侧
    input  wire          wr_clk,    // 写侧时钟
    input  wire          wr_rst_n,  // 写侧复位（低有效）
    input  wire          wr_en,     // 写使能，高有效
    input  wire [DW-1:0] wr_data,   // 写数据
    output wire          full,      // 写满标志，高有效

    // 读侧
    input  wire          rd_clk,    // 读侧时钟
    input  wire          rd_rst_n,  // 读侧复位（低有效）
    input  wire          rd_en,     // 读使能，高有效
    output wire [DW-1:0] rd_data,  // 读数据
    output wire          empty      // 读空标志，高有效
);

    localparam AW = $clog2(DEPTH);

    reg [DW-1:0] mem [0:DEPTH-1];

    reg  [AW:0] wbin, wgray;
    reg  [AW:0] rbin, rgray;

    // 跨域同步
    reg  [AW:0] wgray_s1, wgray_s2;
    reg  [AW:0] rgray_s1, rgray_s2;

    // ---- 写侧 ----
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else if (wr_en && !full) begin
            wbin  <= wbin + 1'b1;
            wgray <= (wbin + 1'b1) ^ ((wbin + 1'b1) >> 1);
        end
    end

    always @(posedge wr_clk) begin
        if (wr_en && !full)
            mem[wbin[AW-1:0]] <= wr_data;
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rgray_s1 <= {(AW+1){1'b0}};
            rgray_s2 <= {(AW+1){1'b0}};
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    // 满：写指针下一位置的高两位与同步来的读指针相反
    wire [AW:0] wbin_next = wbin + 1'b1;
    assign full = (wgray == {~rgray_s2[AW:AW-1], rgray_s2[AW-2:0]});

    // ---- 读侧 ----
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else if (rd_en && !empty) begin
            rbin  <= rbin + 1'b1;
            rgray <= (rbin + 1'b1) ^ ((rbin + 1'b1) >> 1);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wgray_s1 <= {(AW+1){1'b0}};
            wgray_s2 <= {(AW+1){1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    assign empty   = (rgray == wgray_s2);
    assign rd_data = mem[rbin[AW-1:0]];

    // synthesis translate_off
    wire _unused = &{1'b0, wbin_next};
    // synthesis translate_on

endmodule
