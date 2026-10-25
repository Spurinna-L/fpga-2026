`timescale 1ns/1ps
//=============================================================================
// line_sched.v — 行读取调度（video_clk 域）
//-----------------------------------------------------------------------------
// 按 color_bar 的 v_cnt 产生“提前一行”的读取请求：
//   v_cnt=44          -> 预取第 0 行（下一行 v_cnt=45 就是有效行）
//   v_cnt=45..523     -> 预取第 1..479 行（正好在显示上一行时取下一行）
//   v_cnt=524         -> 最后一行正在显示，不再取
//
// 为什么是 44 而不是 43/45：
//   color_bar 在 v_cnt=44 / h_cnt=15 置起 v_active，但该行的有效像素期间
//   v_cnt 已经递增为 45；因此首行必须在 v_cnt=44 预取，提前一整行
//   （约 37.8µs），既够 A+B 1280 字，又不会提前两行造成 bank 冲突。
//
// line_num 在 toggle 前后保持稳定，125MHz 侧用 toggle 边沿锁存。
//=============================================================================
module line_sched (
    input  wire        clk,            // video_clk = 25MHz
    input  wire        rst,
    input  wire        display_valid,
    input  wire [11:0] v_cnt,          // 来自 color_bar

    output reg         line_toggle,
    output reg  [9:0]  line_num,
    output wire        prefetch_zero   // v_cnt=44，通知 sweep 停止
);

    reg [11:0] v_cnt_d;
    reg        frame_en;

    assign prefetch_zero = (v_cnt == 12'd44);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            v_cnt_d     <= 12'd0;
            frame_en    <= 1'b0;
            line_toggle <= 1'b0;
            line_num    <= 10'd0;
        end else begin
            v_cnt_d <= v_cnt;

            if (!display_valid)
                frame_en <= 1'b0;

            if (v_cnt != v_cnt_d) begin
                if (v_cnt == 12'd44) begin
                    frame_en <= display_valid;
                    if (display_valid) begin
                        line_num    <= 10'd0;
                        line_toggle <= ~line_toggle;
                    end
                end else if (frame_en && (v_cnt >= 12'd45) && (v_cnt <= 12'd523)) begin
                    line_num    <= v_cnt - 12'd44;
                    line_toggle <= ~line_toggle;
                end
            end
        end
    end

endmodule
