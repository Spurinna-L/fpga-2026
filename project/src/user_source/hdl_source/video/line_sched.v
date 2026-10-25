`timescale 1ns/1ps
//=============================================================================
// line_sched.v — 行读取调度（video_clk 域）
//-----------------------------------------------------------------------------
// 按 color_bar 的 v_cnt 产生“提前一行”的读取请求：
//   v_cnt=43          -> 预取第 0 行（下一行就是有效行）
//   v_cnt=44..522     -> 预取第 1..479 行（正好在显示上一行时取下一行）
//   v_cnt=523         -> 最后一行正在显示，不再取
//
// 为什么是 43 而不是 44：
//   v_active 在 v_cnt=44 / h_cnt=15 置起，首个有效像素在 h_cnt≈160，
//   只剩 145 个 25MHz 周期（5.8µs）；A+B 共 1280 字需要 10.24µs。
//   提前一整行到 43，可用约 37.8µs，足够覆盖 SDRAM 延迟和命令间隙。
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
    output wire        prefetch_zero   // v_cnt=43，通知 sweep 停止
);

    reg [11:0] v_cnt_d;
    reg        frame_en;

    assign prefetch_zero = (v_cnt == 12'd43);

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
                if (v_cnt == 12'd43) begin
                    frame_en <= display_valid;
                    if (display_valid) begin
                        line_num    <= 10'd0;
                        line_toggle <= ~line_toggle;
                    end
                end else if (frame_en && (v_cnt >= 12'd44) && (v_cnt <= 12'd522)) begin
                    line_num    <= v_cnt - 12'd43;
                    line_toggle <= ~line_toggle;
                end
            end
        end
    end

endmodule
