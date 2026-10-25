`timescale 1ns/1ps
//=============================================================================
// line_buffer.v — 双时钟行缓冲（每个图片源 2 个 bank）
//-----------------------------------------------------------------------------
// 写侧：125MHz，frame_line_read 把一行 640 个像素写到 bank = line_y[0]；
// 读侧：25MHz，显示当前行，bank = pix_y[0]；
// 地址 = {bank, x[9:0]}，深度 2048，正好覆盖 2×1024。
//
// 乒乓关系：
//   显示第 y 行时读 bank=y[0]；同时行读取在写第 y+1 行，bank=(y+1)[0]，
//   两个 bank 不同，因此不会读写冲突。
//
// 复位：BRAM 内容不复位；显示有效性由顶层 display_valid 控制。
//=============================================================================
module line_buffer #(
    parameter WIDTH      = 24,
    parameter ADDR_BITS  = 11
)(
    // 写侧：125MHz
    input  wire                  wr_clk,
    input  wire                  wr_en,
    input  wire [ADDR_BITS-1:0]  wr_addr,
    input  wire [WIDTH-1:0]      wr_data,

    // 读侧：25MHz
    input  wire                  rd_clk,
    input  wire [ADDR_BITS-1:0]  rd_addr,
    output reg  [WIDTH-1:0]      rd_data
);

    reg [WIDTH-1:0] mem [0:(1<<ADDR_BITS)-1];

    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        rd_data <= mem[rd_addr];
    end

endmodule
