`timescale 1ns/1ps
//=============================================================================
// disp_ctrl.v — 显示槽 A/B 与转场进度控制
//-----------------------------------------------------------------------------
// sd_card_bmp 仍然负责“请求显示哪张图”（disp_buf_idx），本模块把它变成
// 真正可动画的 A/B：
//   cur_idx   当前画面（A）
//   next_idx  目标画面（B）
//   alpha     溶解系数，0=A，255=B
//   dx        水平滑动偏移，0=A，640=B
//   mix_mode  0=溶解 1=滑动 2=直通
//
// 只在 vs 下降沿改变状态，保证整帧 A/B 稳定；转场 64 帧 ≈ 1.07s。
// 转场进行中收到新的切图请求不打断当前转场；转场结束后下一 vs 再启动
// 下一段，避免快速按键把画面撕裂。
//=============================================================================
module disp_ctrl #(
    parameter integer TRANS_FRAMES = 64       // 转场帧数（25MHz/60Hz 下 64≈1.07s）
)(
    input  wire        clk,             // video_clk = 25MHz
    input  wire        rst,
    input  wire        display_valid,

    input  wire [1:0]  disp_idx_in,     // 来自 sd_card_bmp（100MHz 域）
    input  wire [1:0]  trans_mode_in,   // 来自 regs（50MHz 域）
    input  wire        frame_tick,      // vs 下降沿，单拍

    output reg  [1:0]  cur_idx,
    output reg  [1:0]  next_idx,
    output reg  [1:0]  mix_mode,
    output reg  [7:0]  alpha,
    output reg  [9:0]  dx,
    output reg         trans_active
);

    // 跨时钟域：只做慢变量 2FF，真正采样在 frame_tick
    reg [1:0] idx_sync0, idx_sync1;
    reg [1:0] mode_sync0, mode_sync1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            idx_sync0  <= 2'd0;
            idx_sync1  <= 2'd0;
            mode_sync0 <= 2'd0;
            mode_sync1 <= 2'd0;
        end else begin
            idx_sync0  <= disp_idx_in;
            idx_sync1  <= idx_sync0;
            mode_sync0 <= trans_mode_in;
            mode_sync1 <= mode_sync0;
        end
    end

    wire [1:0] idx_req  = idx_sync1;
    wire [1:0] mode_req = mode_sync1;

    reg [5:0] prog;      // 0..TRANS_FRAMES-1
    localparam [7:0]  ALPHA_STEP = 256 / TRANS_FRAMES;
    localparam [9:0]  DX_STEP    = 640 / TRANS_FRAMES;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cur_idx      <= 2'd0;
            next_idx     <= 2'd0;
            mix_mode     <= 2'd2;
            alpha        <= 8'd255;
            dx           <= 10'd0;
            trans_active <= 1'b0;
            prog         <= 6'd0;
        end else if (!display_valid) begin
            cur_idx      <= 2'd0;
            next_idx     <= 2'd0;
            mix_mode     <= 2'd2;
            alpha        <= 8'd255;
            dx           <= 10'd0;
            trans_active <= 1'b0;
            prog         <= 6'd0;
        end else if (frame_tick) begin
            if (trans_active) begin
                if (prog == TRANS_FRAMES - 1) begin
                    // 转场结束：目标变成当前，B 跟随 A
                    cur_idx      <= next_idx;
                    next_idx     <= next_idx;
                    mix_mode     <= 2'd2;
                    alpha        <= 8'd255;
                    dx           <= 10'd0;
                    trans_active <= 1'b0;
                    prog         <= 6'd0;
                end else begin
                    prog  <= prog + 6'd1;
                    if (prog == TRANS_FRAMES - 2) begin
                        // 最后一帧直接到 B，避免结束时 10px 的跳变
                        alpha <= 8'd255;
                        dx    <= 10'd640;
                    end else begin
                        alpha <= alpha + ALPHA_STEP;
                        dx    <= dx + DX_STEP;
                    end
                end
            end else begin
                if (idx_req != cur_idx) begin
                    next_idx <= idx_req;
                    if (mode_req == 2'd2) begin
                        // 直切模式
                        cur_idx      <= idx_req;
                        next_idx     <= idx_req;
                        mix_mode     <= 2'd2;
                        alpha        <= 8'd255;
                        dx           <= 10'd0;
                        trans_active <= 1'b0;
                        prog         <= 6'd0;
                    end else begin
                        // 溶解 / 滑动
                        mix_mode     <= mode_req;
                        alpha        <= 8'd0;
                        dx           <= 10'd0;
                        trans_active <= 1'b1;
                        prog         <= 6'd0;
                    end
                end else begin
                    next_idx     <= cur_idx;
                    mix_mode     <= 2'd2;
                    alpha        <= 8'd255;
                    dx           <= 10'd0;
                    trans_active <= 1'b0;
                    prog         <= 6'd0;
                end
            end
        end
    end

endmodule
