//=============================================================================
// test_pattern.v  —  上电测试图（彩条 + 移动方块 + 边框）
//-----------------------------------------------------------------------------
// 作用：在真实素材通路（SD->FAT32->BMP->SDRAM）尚未打通前，先给下游
//       （缩放/OSD/转场/参数处理/HDMI）一个已同步的 720p 图像源，
//       用于验证 720p 时序收敛与 HDMI 输出（里程碑 M1）。
//
// 后续：整条链路完成后，本模块由 `fb_mgr` 的扫描读出数据替代（见 top.v）。
//=============================================================================
`timescale 1ns / 1ps

module test_pattern (
    input  wire        clk_pix, // 像素时钟
    input  wire        rst_n,   // 复位信号，低有效
    input  wire        de,      // 数据使能
    input  wire [10:0] x,       // 当前像素的 X 坐标
    input  wire [10:0] y,       // 当前像素的 Y 坐标
    output reg  [15:0] rgb      // RGB565
);

    // 8 段彩条（每段 160 像素）
    wire [2:0] bar_idx = x[10:8];   // 1280/8=160 -> 用高 3 位近似 8 段
    reg [15:0] bar_rgb;

    always @(*) begin
        case (bar_idx)
            3'd0: bar_rgb = 16'hFFFF; // 白
            3'd1: bar_rgb = 16'hFFE0; // 黄
            3'd2: bar_rgb = 16'h07FF; // 青
            3'd3: bar_rgb = 16'h07E0; // 绿
            3'd4: bar_rgb = 16'hF81F; // 品红
            3'd5: bar_rgb = 16'hF800; // 红
            3'd6: bar_rgb = 16'h001F; // 蓝
            default: bar_rgb = 16'h0000; // 黑
        endcase
    end

    // 移动方块：逐帧水平移动（用 y 行计数做低速游走，便于人眼观察无撕裂）
    reg [10:0] box_x;
    reg [10:0] box_y;
    reg [21:0] move_cnt;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            move_cnt <= 22'd0;
            box_x    <= 11'd100;
            box_y    <= 11'd100;
        end else if (de && x == 11'd0 && y == 11'd0) begin
            move_cnt <= move_cnt + 1'b1;
            if (move_cnt[21]) begin
                // 每约 2^22 像素移动一次
                box_x <= (box_x >= 11'd1100) ? 11'd100 : box_x + 11'd4;
                box_y <= (box_y >= 11'd600)  ? 11'd100 : box_y + 11'd2;
            end
        end
    end

    wire in_box = (x >= box_x) && (x < box_x + 11'd80) &&
                  (y >= box_y) && (y < box_y + 11'd80);
    wire border = (x < 11'd4) || (x >= 11'd1276) || (y < 11'd4) || (y >= 11'd716);

    always @(*) begin
        if (!de)
            rgb = 16'h0000;
        else if (border)
            rgb = 16'hFFFF;
        else if (in_box)
            rgb = 16'hF800;     // 红方块
        else
            rgb = bar_rgb;
    end

endmodule
