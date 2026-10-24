//=============================================================================
// main_fsm.v  —  主控状态机（无处理器）
//-----------------------------------------------------------------------------
// 系统级的"总导演"：上电自检 → 扫描 SD 媒体 → 自动轮播（含转场）；响应用户
// 键盘事件（切图/转场/模式）。所有"会切换画面"的动作只在 frame_start 生效，
// 保证切换无异常（红线③）。
//
// 时钟：clk_pix（74.25MHz），与视频帧对齐；键盘事件由 top 同步为本域单拍脉冲。
//
// 状态：IDLE → SCAN → PLAY；PLAY 中定时/按键触发一次 TRANSITION。
//=============================================================================
`timescale 1ns / 1ps

module main_fsm #(
    parameter AUTO_INTERVAL_FRAMES = 32'd300_000_000   // 约 5s @60fps（示意，集成时用计数分频）
)(
    input  wire        clk_pix,
    input  wire        rst_n,
    input  wire        frame_start,

    // 子模块状态
    input  wire        sd_init_done,
    input  wire        scan_done,
    input  wire [7:0]  media_count,
    input  wire        img_ready,       // 当前图片解码完成、可显示

    // 用户事件（已同步/消抖的单拍脉冲）
    input  wire        ev_next,
    input  wire        ev_prev,
    input  wire        ev_mode,         // 循环切换转场类型
    input  wire        ev_auto,         // 自动轮播开关

    // 输出
    output reg         scan_start,
    output reg  [7:0]  media_index,
    output reg         swap_req,        // 请求在帧末翻转双缓冲
    output reg  [1:0]  transition_mode,
    output reg  [7:0]  blend,           // 转场系数
    output reg         transition_active,
    output reg         auto_play,
    output reg  [2:0]  state
);

    localparam S_IDLE = 3'd0,
               S_SCAN = 3'd1,
               S_PLAY = 3'd2,
               S_TRANS= 3'd3;

    // 自动轮播计时（按帧计数）
    reg [31:0] frame_cnt;
    wire       auto_tick = (frame_cnt == AUTO_INTERVAL_FRAMES);

    // 转场 ramp 计数器（在 frame_start 推进）
    reg [7:0] blend_cnt;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            scan_start        <= 1'b0;
            media_index       <= 8'd0;
            swap_req          <= 1'b0;
            transition_mode   <= 2'd0;
            blend             <= 8'd0;
            transition_active <= 1'b0;
            auto_play         <= 1'b1;
            frame_cnt         <= 32'd0;
            blend_cnt         <= 8'd0;
        end else begin
            scan_start <= 1'b0;
            swap_req   <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (sd_init_done) begin
                        state      <= S_SCAN;
                        scan_start <= 1'b1;
                    end
                end

                S_SCAN: begin
                    if (scan_done) begin
                        state       <= S_PLAY;
                        media_index <= 8'd0;
                        frame_cnt   <= 32'd0;
                    end
                end

                S_PLAY: begin
                    // 自动轮播计时
                    if (frame_start) begin
                        if (auto_tick) frame_cnt <= 32'd0;
                        else           frame_cnt <= frame_cnt + 1'b1;
                    end

                    // 触发转场：按键优先，其次自动
                    if (ev_next || (auto_play && auto_tick)) begin
                        state       <= S_TRANS;
                        blend_cnt   <= 8'd0;
                        blend       <= 8'd0;
                        swap_req    <= 1'b1;             // 帧末换缓冲
                        transition_active <= 1'b1;
                        if (media_count != 8'd0 && (media_index + 1'b1) >= media_count)
                            media_index <= 8'd0;
                        else
                            media_index <= media_index + 1'b1;
                    end else if (ev_prev) begin
                        state     <= S_TRANS;
                        blend_cnt <= 8'd0;
                        blend     <= 8'd0;
                        swap_req  <= 1'b1;
                        transition_active <= 1'b1;
                        media_index <= (media_index == 8'd0) ?
                                       (media_count - 1'b1) : (media_index - 1'b1);
                    end else if (ev_mode) begin
                        transition_mode <= transition_mode + 1'b1;
                    end else if (ev_auto) begin
                        auto_play <= ~auto_play;
                    end
                end

                S_TRANS: begin
                    if (frame_start) begin
                        if (blend_cnt == 8'd255) begin
                            transition_active <= 1'b0;
                            blend             <= 8'd0;
                            state             <= S_PLAY;
                            frame_cnt         <= 32'd0;
                        end else begin
                            blend_cnt <= blend_cnt + 8'd8;   // 约 32 帧完成
                            blend     <= blend_cnt;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, img_ready};
    // synthesis translate_on

endmodule
