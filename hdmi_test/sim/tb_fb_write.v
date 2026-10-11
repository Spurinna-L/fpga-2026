//=============================================================================
// tb_fb_write.v  —  Phase 3 验证：stub_source → fb_mgr(写侧) → sdram_bhv
//-----------------------------------------------------------------------------
// 流程：让假数据源写完一帧，经 fb_mgr 推进 SDRAM 的 WR1；
//       然后把 sdram_bhv 内部内存 dump 成 BMP，并逐像素与"期望图案"比对。
// 验收：SDRAM 里的内容 == 假数据源产生的图。
//=============================================================================
`timescale 1ns / 1ps

module tb_fb_write;

    localparam W = 1280;
    localparam H = 720;
    localparam N = W*H;

    // ---- 时钟 ----
    reg clk_wr = 0, ctrl = 0;
    always #10 clk_wr = ~clk_wr;   // 50 MHz
    always #5  ctrl   = ~ctrl;     // 100 MHz

    reg rst_n = 0;

    // ---- stub_source ----
    wire        px_we;
    wire [10:0] px_x, px_y;
    wire [15:0] px_pix;
    wire        frame_done;
    wire        wr_stall;
    reg         hold = 0;

    stub_source #(.W(W), .H(H)) u_stub (
        .clk       (clk_wr),
        .rst_n     (rst_n),
        .stall     (wr_stall | hold),
        .frame_id  (8'd0),
        .px_we     (px_we),
        .px_x      (px_x),
        .px_y      (px_y),
        .px_pix    (px_pix),
        .frame_done(frame_done)
    );

    // ---- fb_mgr（写侧）----
    wire [15:0] wr1_data; wire wr1_req; wire [20:0] wr1_addr, wr1_max; wire [9:0] wr1_len;
    wire [15:0] wr2_data; wire wr2_req; wire [20:0] wr2_addr, wr2_max; wire [9:0] wr2_len;
    wire wr1_load, wr2_load, wr1_full, wr2_full;

    fb_mgr #(.W(W), .H(H)) u_fb (
        .clk_wr     (clk_wr),
        .rst_n_wr   (rst_n),
        .px_we      (px_we),
        .px_x       (px_x),
        .px_y       (px_y),
        .px_pix     (px_pix),
        .frame_done (frame_done),
        .wr_stall   (wr_stall),

        .wr1_data   (wr1_data), .wr1_req(wr1_req), .wr1_addr(wr1_addr),
        .wr1_max_addr(wr1_max), .wr1_length(wr1_len), .wr1_load(wr1_load),
        .wr1_clk(), .wr1_full(wr1_full),

        .wr2_data   (wr2_data), .wr2_req(wr2_req), .wr2_addr(wr2_addr),
        .wr2_max_addr(wr2_max), .wr2_length(wr2_len), .wr2_load(wr2_load),
        .wr2_clk(), .wr2_full(wr2_full),

        // 读侧本测试台不使用：保持复位、输入给安全值
        .clk_pix(1'b0), .rst_n_pix(1'b0),
        .de_i(1'b0), .hs_i(1'b0), .vs_i(1'b0), .frame_start(1'b0),
        .fallback_rgb(16'h0000),
        .rd1_data(16'h0000), .rd1_empty(1'b1), .rd1_req(),
        .rd1_addr(), .rd1_max_addr(), .rd1_length(), .rd1_load(), .rd1_clk(),
        .rd2_data(16'h0000), .rd2_empty(1'b1), .rd2_req(),
        .rd2_addr(), .rd2_max_addr(), .rd2_length(), .rd2_load(), .rd2_clk(),
        .rgb_o(), .de_o(), .hs_o(), .vs_o(), .underrun(), .front_o()
    );

    // ---- SDRAM 行为模型 ----
    sdram_bhv u_sdram (
        .CTRL_CLK(ctrl), .SDRAM_CLK(ctrl), .RESET_N(rst_n),

        .WR1_DATA(wr1_data), .WR1(wr1_req), .WR1_ADDR(wr1_addr), .WR1_MAX_ADDR(wr1_max),
        .WR1_LENGTH(wr1_len), .WR1_LOAD(wr1_load), .WR1_CLK(clk_wr),
        .WR1_FULL(wr1_full), .WR1_USE(),

        .WR2_DATA(wr2_data), .WR2(wr2_req), .WR2_ADDR(wr2_addr), .WR2_MAX_ADDR(wr2_max),
        .WR2_LENGTH(wr2_len), .WR2_LOAD(wr2_load), .WR2_CLK(clk_wr),
        .WR2_FULL(wr2_full), .WR2_USE(),

        .RD1_DATA(), .RD1(1'b0), .RD1_ADDR(21'd0), .RD1_MAX_ADDR(21'd0),
        .RD1_LENGTH(10'd16), .RD1_LOAD(1'b0), .RD1_CLK(ctrl), .RD1_EMPTY(), .RD1_USE(),

        .RD2_DATA(), .RD2(1'b0), .RD2_ADDR(21'd0), .RD2_MAX_ADDR(21'd0),
        .RD2_LENGTH(10'd16), .RD2_LOAD(1'b0), .RD2_CLK(ctrl), .RD2_EMPTY(), .RD2_USE()
    );

    // ---- 期望图案（与 stub_source 保持一致）----
    function [15:0] pat;
        input integer x, y;
        reg [7:0] rr, gg, bb;
        begin
            rr = x[7:0];
            gg = y[7:0];
            bb = (x[7] ^ y[7]) ? 8'hFF : 8'h00;
            if (x < 4 || x >= W-4 || y < 4 || y >= H-4)
                pat = 16'hFFFF;
            else
                pat = {rr[7:3], gg[7:2], bb[7:3]};
        end
    endfunction

    // ---- BMP 输出 ----
    integer fd;
    task bmp_u16; input [15:0] v;
        begin $fwrite(fd,"%c",v[7:0]); $fwrite(fd,"%c",v[15:8]); end
    endtask
    task bmp_u32; input [31:0] v;
        begin $fwrite(fd,"%c",v[7:0]); $fwrite(fd,"%c",v[15:8]);
                    $fwrite(fd,"%c",v[23:16]); $fwrite(fd,"%c",v[31:24]); end
    endtask

    integer i, errors;
    reg [15:0] m;

    initial begin
        fd = $fopen("fb_frame.bmp", "wb");
        if (fd == 0) begin $display("[tb] ERROR: cannot open fb_frame.bmp"); $finish; end
        bmp_u16(16'h4D42); bmp_u32(W*3*H+54); bmp_u32(0); bmp_u32(54);
        bmp_u32(40); bmp_u32(W); bmp_u32(-H);
        bmp_u16(1); bmp_u16(24); bmp_u32(0); bmp_u32(W*3*H);
        bmp_u32(2835); bmp_u32(2835); bmp_u32(0); bmp_u32(0);

        $display("[tb] 复位释放，开始写一帧 ...");
        #100 rst_n = 1'b1;
    end

    initial begin
        @(posedge rst_n);
        @(posedge frame_done);              // 等一帧写完
        hold = 1'b1;                        // 暂停上游
        #20000;                             // 等 FIFO 排空进内存

        errors = 0;
        for (i = 0; i < N; i = i + 1) begin
            m = u_sdram.mem[i];
            if (m !== pat(i % W, i / W)) begin
                errors = errors + 1;
                if (errors <= 8) $display("   [错] i=%0d (x=%0d,y=%0d) mem=%h exp=%h",
                                          i, i%W, i/W, m, pat(i%W, i/W));
            end
            $fwrite(fd, "%c%c%c", {m[4:0],m[4:2]}, {m[10:5],m[10:9]}, {m[15:11],m[15:13]});
        end
        $fclose(fd);

        if (errors == 0)
            $display("[tb] === PASS: SDRAM 里 %0d 个像素与假数据源完全一致 ===", N);
        else
            $display("[tb] === FAIL: %0d 个像素不一致 ===", errors);
        $display("[tb] SDRAM 内容已 dump -> fb_frame.bmp");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("[tb] TIMEOUT");
        $finish;
    end

endmodule
