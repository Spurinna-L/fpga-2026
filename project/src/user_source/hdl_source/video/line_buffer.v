`timescale 1ns/1ps
//=============================================================================
// line_buffer.v — 双时钟行缓冲（显式 EG_LOGIC_BRAM，PDPW 模式）
//-----------------------------------------------------------------------------
// 为什么不用推断 RAM：
//   TD 对“两个 always 块 + 两个时钟”的推断 RAM 行为不够确定；这里直接用
//   官方 IP 生成器同款 EG_LOGIC_BRAM（PDPW：A 口写、B 口读），行为与
//   Camera/LCD 例程一致，读延迟固定 1 拍。
//
// 写侧：125MHz，frame_line_read 把一行 640 个像素写到 bank = line_y[0]；
// 读侧：25MHz，显示当前行，bank = pix_y[0]；
// 地址 = {bank, x[9:0]}，深度 2048，正好覆盖 2×1024。
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
    output wire [WIDTH-1:0]      rd_data
);

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A  (WIDTH),
        .DATA_WIDTH_B  (WIDTH),
        .ADDR_WIDTH_A  (ADDR_BITS),
        .ADDR_WIDTH_B  (ADDR_BITS),
        .DATA_DEPTH_A  (1 << ADDR_BITS),
        .DATA_DEPTH_B  (1 << ADDR_BITS),
        .MODE          ("PDPW"),
        .REGMODE_A     ("NOREG"),
        .REGMODE_B     ("NOREG"),
        .WRITEMODE_A   ("NORMAL"),
        .WRITEMODE_B   ("NORMAL"),
        .RESETMODE     ("SYNC"),
        .IMPLEMENT     ("9K"),
        .INIT_FILE     ("NONE"),
        .FILL_ALL      ("NONE")
    ) u_ram (
        .dia   (wr_data),
        .dib   ({WIDTH{1'b0}}),
        .addra (wr_addr),
        .addrb (rd_addr),
        .cea   (wr_en),
        .ceb   (1'b1),
        .ocea  (1'b0),
        .oceb  (1'b0),
        .clka  (wr_clk),
        .clkb  (rd_clk),
        .wea   (1'b1),
        .web   (1'b0),
        .bea   (1'b0),
        .beb   (1'b0),
        .rsta  (1'b0),
        .rstb  (1'b0),
        .doa   (),
        .dob   (rd_data)
    );

endmodule
