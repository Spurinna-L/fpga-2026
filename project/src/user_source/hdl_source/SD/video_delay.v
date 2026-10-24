//=============================================================================
// video_delay.v — 视频流水线对齐（双路 RGB888 + 像素坐标 x/y）
//-----------------------------------------------------------------------------
// 功能：
//   与官方单路版本保持完全相同的 21 拍延迟结构：
//     read_en = de_d[18]   提前一拍从帧缓存 FIFO 弹出像素
//     de_d[19]             锁存 FIFO 输出（FIFO 读延迟 1 拍）
//     de_d[20]             对外 de_r，此时 vout_data_* 有效
//   并输出与 de_r 严格同拍的像素坐标 x(0..639) / y(0..479)。
//
// 时钟/复位：video_clk = 25MHz；rst 高有效。
//
// 接口：
//   in  hs / vs / de            来自 video_timing_data
//   in  read_data_a / _b[23:0]  帧缓存 A/B 通道像素
//   out read_en                 FIFO 读使能
//   out hs_r / vs_r / de_r      延迟 21 拍的时序
//   out vout_data_a / _b[23:0]  对齐后的像素
//   out x / y[9:0]              像素坐标（同拍）
//
// 参数：
//   DATA_WIDTH = 24
//
// 内部例化：无
//
// 备注：
//   x/y 在 vs 下降沿清零（本工程 vs 为负极性，与 read_req 触发沿一致）；
//   当前顶层只用 A 通道，B 通道为 M2 转场预留。
//=============================================================================
`timescale 1ns/1ps

module video_delay
#
(
    parameter DATA_WIDTH = 24
)
(
    input                       video_clk,
    input                       rst,
    output                      read_en,
    input  [DATA_WIDTH - 1:0]   read_data_a,
    input  [DATA_WIDTH - 1:0]   read_data_b,
    input                       hs,
    input                       vs,
    input                       de,

    output                      hs_r,
    output                      vs_r,
    output                      de_r,
    output [DATA_WIDTH - 1:0]   vout_data_a,
    output [DATA_WIDTH - 1:0]   vout_data_b,
    output [9:0]                x,
    output [9:0]                y
);

    reg [20:0] hs_d;
    reg [20:0] vs_d;
    reg [20:0] de_d;

    reg [DATA_WIDTH - 1:0] vout_data_a_r;
    reg [DATA_WIDTH - 1:0] vout_data_b_r;

    reg [9:0] x_r;
    reg [9:0] y_r;
    reg       vs_r_d;
    wire      vs_fall = vs_r_d & ~vs_r;   // 本工程 vs 负极性

    assign read_en    = de_d[18];
    assign hs_r       = hs_d[20];
    assign vs_r       = vs_d[20];
    assign de_r       = de_d[20];
    assign vout_data_a = vout_data_a_r;
    assign vout_data_b = vout_data_b_r;
    assign x          = x_r;
    assign y          = y_r;

    // 双路像素同步锁存
    always @(posedge video_clk or posedge rst)
    begin
        if (rst == 1'b1) begin
            vout_data_a_r <= {DATA_WIDTH{1'b0}};
            vout_data_b_r <= {DATA_WIDTH{1'b0}};
        end else if (de_d[19]) begin
            vout_data_a_r <= read_data_a;
            vout_data_b_r <= read_data_b;
        end else begin
            vout_data_a_r <= {DATA_WIDTH{1'b0}};
            vout_data_b_r <= {DATA_WIDTH{1'b0}};
        end
    end

    // hs/vs/de 21 拍延迟
    always @(posedge video_clk or posedge rst)
    begin
        if (rst) begin
            hs_d <= 21'b0;
            vs_d <= 21'b0;
            de_d <= 21'b0;
        end else begin
            hs_d <= {hs_d[19:0], hs};
            vs_d <= {vs_d[19:0], vs};
            de_d <= {de_d[19:0], de};
        end
    end

    // 像素坐标：与 de_r / vs_r 同拍
    always @(posedge video_clk or posedge rst)
    begin
        if (rst) begin
            x_r    <= 10'd0;
            y_r    <= 10'd0;
            vs_r_d <= 1'b1;
        end else begin
            vs_r_d <= vs_r;

            if (vs_fall) begin
                x_r <= 10'd0;
                y_r <= 10'd0;
            end else if (de_r) begin
                if (x_r == 10'd639) begin
                    x_r <= 10'd0;
                    y_r <= (y_r == 10'd479) ? 10'd0 : (y_r + 10'd1);
                end else begin
                    x_r <= x_r + 10'd1;
                end
            end
        end
    end

endmodule
