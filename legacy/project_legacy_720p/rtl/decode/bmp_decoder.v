//=============================================================================
// bmp_decoder.v  —  BMP 图片解码（自研）
//-----------------------------------------------------------------------------
// 输入：来自 fat32_reader 的 BMP 文件字节流（file_data/file_valid/file_pop）。
// 输出：像素流（RGB565）+ 行列坐标 + 写使能，供写入 SDRAM 帧缓冲。
//
// 支持范围（按赛题素材规范）：
//   - 24bit / 32bit 非压缩 BMP；
//   - 行 4 字节对齐补齐（BMP 每行字节数为 4 的倍数）；
//   - 自底向上（biHeight>0）与自顶向下（biHeight<0）两种行序。
// 解析流程：BITMAPFILEHEADER(14B) → BITMAPINFOHEADER(40B) → 像素阵列。
//
// 【当前状态】接口骨架；头部解析与像素打包在第 2 周实现（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module bmp_decoder (
    input  wire        clk,
    input  wire        rst_n,

    // 文件字节流（来自 fat32_reader）
    output wire        file_pop,
    input  wire        file_valid,
    input  wire [7:0]  file_data,

    // 图像信息
    output reg  [15:0] img_w,
    output reg  [15:0] img_h,
    output reg         header_ok,
    output reg         frame_done,

    // 像素写（→ SDRAM 帧缓冲）
    output reg  [15:0] px_data,     // RGB565
    output reg  [15:0] px_x,
    output reg  [15:0] px_y,
    output reg         px_we
);

    // TODO(第 2 周):
    //   1) 缓存 14+40 字节头，解析 bfOffBits / biWidth / biHeight / biBitCount；
    //   2) 计算行字节数 row_bytes = ((w*bpp+31)/32)*4，跳过补齐字节；
    //   3) 24bit: 每 3 字节 B,G,R → RGB565；32bit: 每 4 字节 B,G,R,A；
    //   4) biHeight<0 时按自上而下输出，否则 y 反向映射；
    //   5) 输出 px_we 逐像素写入帧缓冲，frame_done 在本帧最后一像素处置位。

    assign file_pop = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            img_w      <= 16'd0;
            img_h      <= 16'd0;
            header_ok  <= 1'b0;
            frame_done <= 1'b0;
            px_data    <= 16'd0;
            px_x       <= 16'd0;
            px_y       <= 16'd0;
            px_we      <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            px_we      <= 1'b0;
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, file_valid, file_data};
    // synthesis translate_on

endmodule
