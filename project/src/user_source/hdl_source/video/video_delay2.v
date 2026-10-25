`timescale 1ns/1ps
//=============================================================================
// video_delay2.v — 固定 2 拍视频边带延迟
//-----------------------------------------------------------------------------
// M2 行缓冲通路的固定延迟：
//   line_buffer 同步读 1 拍 + mixer 输出寄存 1 拍 = 2 拍
// 把 hs/vs/de/x/y 打包成一条总线，整体延迟 2 拍，保证与 RGB 严格同拍。
//=============================================================================
module video_delay2 #(
    parameter WIDTH = 23
)(
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);

    reg [WIDTH-1:0] d0, d1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            d0 <= {WIDTH{1'b0}};
            d1 <= {WIDTH{1'b0}};
        end else begin
            d0 <= din;
            d1 <= d0;
        end
    end

    assign dout = d1;

endmodule
