//=============================================================================
// transition.v  —  图片切换转场引擎
//-----------------------------------------------------------------------------
// 对应扩展要求 ②。在 A/B 两帧之间按 mode 混合，切换只允许在场消隐内启动
// （由上层 main_fsm 用 frame_start 对齐 blend/ mode 的更新）。
//
// mode: 0=淡入淡出/交叉溶解, 1=水平滑动(slide), 2=水平擦除(wipe), 3=垂直擦除
// blend: 0→A 完全显示；255→B 完全显示；中间过渡。
//
// 全流水：输入 a/b 与 hs/vs/de 同步，输出打一拍，保证不撕裂。
//=============================================================================
`timescale 1ns / 1ps

module transition (
    input  wire        clk_pix,
    input  wire        rst_n,

    input  wire [15:0] a_rgb,
    input  wire [15:0] b_rgb,
    input  wire        hs_i,
    input  wire        vs_i,
    input  wire        de_i,
    input  wire [10:0] x,           // 当前列（de 有效）
    input  wire [10:0] y,           // 当前行（de 有效）

    input  wire [1:0]  mode,        // 转场类型
    input  wire [7:0]  blend,       // 过渡系数

    output reg  [15:0] rgb_o,
    output reg         hs_o,
    output reg         vs_o,
    output reg         de_o
);

    localparam H_ACTIVE = 1280;
    localparam V_ACTIVE = 720;

    // 边界位置（滑动/擦除用）
    wire [10:0] h_bound = (blend * H_ACTIVE) >> 8;   // 0..1279
    wire [10:0] v_bound = (blend * V_ACTIVE) >> 8;   // 0..719

    // 交叉溶解：out = (a*(255-blend) + b*blend) / 255 ≈ >>8
    function [15:0] dissolve;
        input [15:0] a;
        input [15:0] b;
        input [7:0]  t;
        reg [23:0] ra, ga, ba, rb, gb, bb;
        begin
            ra = a[15:11]; ga = a[10:5]; ba = a[4:0];
            rb = b[15:11]; gb = b[10:5]; bb = b[4:0];
            dissolve = {
                (ra*(8'd255-t) + rb*t) >> 8,
                (ga*(8'd255-t) + gb*t) >> 8,
                (ba*(8'd255-t) + bb*t) >> 8
            };
        end
    endfunction

    reg [15:0] sel;
    always @(*) begin
        case (mode)
            2'd0: sel = dissolve(a_rgb, b_rgb, blend);        // 淡入淡出/溶解
            2'd1: sel = (x < h_bound) ? b_rgb : a_rgb;        // 水平滑动
            2'd2: sel = (x >= (H_ACTIVE - h_bound)) ? b_rgb : a_rgb; // 水平擦除(右→左)
            default: sel = (y < v_bound) ? b_rgb : a_rgb;     // 垂直擦除
        endcase
    end

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            rgb_o <= 16'd0;
            hs_o  <= 1'b0;
            vs_o  <= 1'b0;
            de_o  <= 1'b0;
        end else begin
            rgb_o <= de_i ? sel : 16'd0;
            hs_o  <= hs_i;
            vs_o  <= vs_i;
            de_o  <= de_i;
        end
    end

endmodule
