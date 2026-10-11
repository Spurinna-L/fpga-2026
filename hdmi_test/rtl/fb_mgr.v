//=============================================================================
// fb_mgr.v  —  帧缓冲管家（Phase 5：双缓冲 + 换班握手）
//-----------------------------------------------------------------------------
// 职责：
//   【写侧】(系统 50MHz 域) 把上游像素流写进"后台"缓冲(WR1/WR2)，FIFO 满时反压。
//   【读侧】(像素域)       从"前台"缓冲(RD1/RD2)按扫描读出。
//
// 双缓冲模型：
//   · front (像素域)：前台是哪块，决定读 RD1/RD2；
//   · wr_buf(写域)  ：后台是哪块，决定写 WR1/WR2；与 front 互补。
//   · 换班只允许发生在"垂直消隐期"(vs 有效) → 绝不在扫描中途换 → 不撕裂。
//
// 换班握手（跨时钟域，均为单比特事件，用 toggle+同步+边沿检测）：
//   写域：一帧写完(frame_done) → busy=1、翻转 swap_tgl，并暂停上游；
//   像素域：同步 swap_tgl → pending；在 vs 有效时翻转 front、置 buf_ready、
//           翻转 ack_tgl；
//   写域：同步 ack_tgl 回来 → busy=0、翻转 wr_buf，恢复上游写下一帧。
//
// 上电：front=1、wr_buf=0（第一帧写 A）；buf_ready=0 时输出 fallback_rgb。
//=============================================================================
`timescale 1ns / 1ps

module fb_mgr #(
    parameter W         = 1280,
    parameter H         = 720,
    parameter AW        = 21,
    parameter FB_A_BASE = 21'd0,
    parameter FB_B_BASE = 21'd921600,
    parameter RD_PIPE   = 0,       // 读侧输出补拍数（真 FIFO 若为寄存输出可设 1）
    parameter RD_LD_FRM = 0        // 【推荐 0】仅初始化时 LOAD 一次，读指针靠"自动回绕"对齐；
                                   // 【勿用 1】每帧消隐期也 LOAD —— 会把读指针推偏（实测偏移~半屏）
)(
    //--------------------- 写侧（系统 50MHz 域，I1）----------------------
    input  wire          clk_wr,
    input  wire          rst_n_wr,
    input  wire          px_we,
    input  wire [10:0]   px_x,
    input  wire [10:0]   px_y,
    input  wire [15:0]   px_pix,
    input  wire          frame_done,
    output wire          wr_stall,

    output wire [15:0]   wr1_data,
    output wire          wr1_req,
    output wire [AW-1:0] wr1_addr,
    output wire [AW-1:0] wr1_max_addr,
    output wire [9:0]    wr1_length,
    output wire          wr1_load,
    output wire          wr1_clk,
    input  wire          wr1_full,

    output wire [15:0]   wr2_data,
    output wire          wr2_req,
    output wire [AW-1:0] wr2_addr,
    output wire [AW-1:0] wr2_max_addr,
    output wire [9:0]    wr2_length,
    output wire          wr2_load,
    output wire          wr2_clk,
    input  wire          wr2_full,

    //--------------------- 读侧（像素域）--------------------------------
    input  wire          clk_pix,
    input  wire          rst_n_pix,
    input  wire          de_i,
    input  wire          hs_i,
    input  wire          vs_i,          // 换班点：在 vs 有效(垂直消隐)时换
    input  wire          frame_start,   // 备用（本实现用 vs 触发换班）
    input  wire [15:0]   fallback_rgb,

    input  wire [15:0]   rd1_data,
    input  wire          rd1_empty,
    output wire          rd1_req,
    output wire [AW-1:0] rd1_addr,
    output wire [AW-1:0] rd1_max_addr,
    output wire [9:0]    rd1_length,
    output wire          rd1_load,
    output wire          rd1_clk,

    input  wire [15:0]   rd2_data,
    input  wire          rd2_empty,
    output wire          rd2_req,
    output wire [AW-1:0] rd2_addr,
    output wire [AW-1:0] rd2_max_addr,
    output wire [9:0]    rd2_length,
    output wire          rd2_load,
    output wire          rd2_clk,

    output wire [15:0]   rgb_o,
    output wire          de_o,
    output wire          hs_o,
    output wire          vs_o,
    output wire          underrun,
    output wire          front_o,        // 调试：当前前台
    output wire          buf_ready_o     // 调试：画面是否就绪
);

    localparam [AW-1:0] FB_A_END = FB_A_BASE + W*H;
    localparam [AW-1:0] FB_B_END = FB_B_BASE + W*H;

    //=====================================================================
    // 跨域状态（先声明，后使用）
    //=====================================================================
    // 写域
    reg  [3:0] init_cnt;
    reg        wr_ready;
    reg        wr_buf;                 // 后台选择
    reg        busy;                   // 一帧写完，等换班
    reg        swap_tgl;               // 写域 -> 像素域 的换班请求(toggle)
    reg        ack_tgl_s, ack_tgl_sd;  // 像素域 ack(toggle) 同步到写域
    reg  [3:0] wl_cnt;                 // >0：正在给写口发 LOAD

    // 像素域
    reg        front;                  // 前台缓冲
    reg        buf_ready;              // 有可显示画面
    reg        pending;                // 有换班请求待执行
    reg        ack_tgl;                // 像素域 -> 写域 的换班确认(toggle)
    reg        swap_tgl_s, swap_tgl_sd;// 写域 swap_tgl 同步到像素域
    reg  [3:0] rd_init_cnt;
    reg  [3:0] rdl_cnt;                // >0：正在给前台读口发 LOAD
    reg        rd_ready;

    wire ack_p      = ack_tgl_s ^ ack_tgl_sd;      // 写域：换班确认脉冲
    wire swap_req_p = swap_tgl_s ^ swap_tgl_sd;    // 像素域：换班请求脉冲

    assign wr1_clk = clk_wr;
    assign wr2_clk = clk_wr;
    assign rd1_clk = clk_pix;
    assign rd2_clk = clk_pix;

    //=====================================================================
    // 写侧
    //=====================================================================
    assign wr1_addr     = FB_A_BASE;
    assign wr1_max_addr = FB_A_END;
    assign wr1_length   = 10'd256;
    assign wr2_addr     = FB_B_BASE;
    assign wr2_max_addr = FB_B_END;
    assign wr2_length   = 10'd256;

    assign wr1_data = px_pix;
    assign wr2_data = px_pix;

    assign wr1_req  = px_we & ~wr_buf & ~wr1_full;
    assign wr2_req  = px_we &  wr_buf & ~wr2_full;

    // 反压：初始化中 / 等换班 / 本拍正是帧末 / FIFO 满 → 暂停上游
    //   ⚠ 必须包含 frame_done：否则帧末那一拍上游会多吐 1 个像素，
    //     写进旧缓冲，导致下一块缓冲整体错位 1 像素。
    assign wr_stall = ~wr_ready | busy | frame_done | (wr_buf ? wr2_full : wr1_full);

    // 写口 LOAD 电平：初始化 + 换班后给"新写口"对齐指针
    assign wr1_load = (init_cnt < 4'd4) | ((wl_cnt != 4'd0) & ~wr_buf);
    assign wr2_load = (init_cnt < 4'd4) | ((wl_cnt != 4'd0) &  wr_buf);

    always @(posedge clk_wr or negedge rst_n_wr) begin
        if (!rst_n_wr) begin
            init_cnt   <= 4'd0;
            wr_ready   <= 1'b0;
            wr_buf     <= 1'b0;      // 第一帧写 A
            busy       <= 1'b0;
            swap_tgl   <= 1'b0;
            ack_tgl_s  <= 1'b0;
            ack_tgl_sd <= 1'b0;
            wl_cnt     <= 4'd0;
        end else begin
            // 初始化
            if (init_cnt < 4'd4) begin
                init_cnt <= init_cnt + 1'b1;
                wr_ready <= 1'b0;
            end else begin
                wr_ready <= 1'b1;
            end

            // 同步像素域的 ack
            ack_tgl_s  <= ack_tgl;
            ack_tgl_sd <= ack_tgl_s;

            if (wl_cnt != 4'd0)
                wl_cnt <= wl_cnt - 1'b1;

            // 一帧写完 → 请求换班 + 暂停上游
            if (frame_done) begin
                busy     <= 1'b1;
                swap_tgl <= ~swap_tgl;
            end

            // 换班确认 → 切换写口 + 给新写口 LOAD（对齐指针，规避突发粒度漂移）
            if (ack_p) begin
                wr_buf <= ~wr_buf;
                wl_cnt <= 4'd10;
            end

            // LOAD 结束后再放行上游
            if (wl_cnt == 4'd1)
                busy <= 1'b0;
        end
    end

    //=====================================================================
    // 读侧
    //=====================================================================
    assign rd1_addr     = FB_A_BASE;
    assign rd1_max_addr = FB_A_END;
    assign rd1_length   = 10'd256;
    assign rd2_addr     = FB_B_BASE;
    assign rd2_max_addr = FB_B_END;
    assign rd2_length   = 10'd256;

    // 读指针 LOAD：
    //   · 复位后先 LOAD 一次；
    //   · 每次"换班"再对新前台端口 LOAD（复位指针 + 清 FIFO），让它在垂直
    //     消隐期用**最新写完的数据**重新预取 —— 消除"陈旧预取"，并保证对齐。
    wire rdl = (rdl_cnt != 4'd0);
    assign rd1_load = (rd_init_cnt < 4'd4) | (rdl & ~front);
    assign rd2_load = (rd_init_cnt < 4'd4) | (rdl &  front);

    always @(posedge clk_pix or negedge rst_n_pix) begin
        if (!rst_n_pix) begin
            rd_init_cnt <= 4'd0;
            rd_ready    <= 1'b0;
        end else if (rd_init_cnt < 4'd4) begin
            rd_init_cnt <= rd_init_cnt + 1'b1;
            rd_ready    <= 1'b0;
        end else begin
            rd_ready    <= 1'b1;
        end
    end

    // 换班握手 + 换班时给新前台端口发 LOAD（像素域）
    always @(posedge clk_pix or negedge rst_n_pix) begin
        if (!rst_n_pix) begin
            front       <= 1'b1;     // 初始指向 B；第一帧写 A
            buf_ready   <= 1'b0;
            pending     <= 1'b0;
            ack_tgl     <= 1'b0;
            swap_tgl_s  <= 1'b0;
            swap_tgl_sd <= 1'b0;
            rdl_cnt     <= 4'd0;
        end else begin
            // 同步写域的 swap_tgl
            swap_tgl_s  <= swap_tgl;
            swap_tgl_sd <= swap_tgl_s;

            if (swap_req_p) pending <= 1'b1;

            if (rdl_cnt != 4'd0)
                rdl_cnt <= rdl_cnt - 1'b1;

            // 每帧垂直消隐期(vs 有效)：
            //   · 若有待换班请求，则翻转 front / 置 buf_ready / 回 ack；
            //   · 无论是否换班，都对"前台"读口发 LOAD。
            // 为什么要每帧 LOAD：真控制器 Sdram_Control_4Port 是"突发预取"的，
            // 读地址寄存器按整批(RD1_LENGTH)前进、且会抢跑，导致弹出的字数与读出的
            // 字数不严格相等 → 指针逐帧漂移（表现为画面偏移 + 左右晃动）。
            // 每帧消隐期强制 LOAD，把读指针拉回基址，彻底消除漂移。
            if (vs_i) begin
                if (pending) begin
                    front     <= ~front;
                    pending   <= 1'b0;
                    buf_ready <= 1'b1;
                    ack_tgl   <= ~ack_tgl;
                end
                if (RD_LD_FRM) rdl_cnt <= 4'd10;
            end
        end
    end

    // 只从"前台"读口取数；且仅在已有画面(buf_ready)时取
    assign rd1_req = de_i & rd_ready & buf_ready & ~front;
    assign rd2_req = de_i & rd_ready & buf_ready &  front;

    wire [15:0] rd_sel_data  = front ? rd2_data  : rd1_data;
    wire        rd_sel_empty = front ? rd2_empty : rd1_empty;

    assign underrun = de_i & rd_ready & buf_ready & rd_sel_empty;

    // 读侧输出（可选补拍 RD_PIPE）：
    //   真控制器读 FIFO 是 softfifo 的 show-ahead（0 拍），故默认 RD_PIPE=0；
    //   若某版本 FIFO 为寄存输出，可把 RD_PIPE 设为 1 来对齐（整幅平移 1 像素）。
    //   就绪前显示 fallback(测试图)；就绪后若读 FIFO 空(欠载)则输出黑色（便于诊断）。
    wire [15:0] rgb_c = buf_ready ? (rd_sel_empty ? 16'h0000 : rd_sel_data) : fallback_rgb;
    wire        de_c  = de_i & rd_ready;

    reg [15:0] rgb_q;
    reg        de_q, hs_q, vs_q;
    always @(posedge clk_pix or negedge rst_n_pix) begin
        if (!rst_n_pix) begin
            rgb_q <= 16'd0; de_q <= 1'b0; hs_q <= 1'b0; vs_q <= 1'b0;
        end else begin
            rgb_q <= rgb_c;
            de_q  <= de_c;
            hs_q  <= hs_i;
            vs_q  <= vs_i;
        end
    end

    assign rgb_o  = RD_PIPE ? rgb_q : rgb_c;
    assign de_o   = RD_PIPE ? de_q  : de_c;
    assign hs_o   = RD_PIPE ? hs_q  : hs_i;
    assign vs_o   = RD_PIPE ? vs_q  : vs_i;
    assign front_o = front;
    assign buf_ready_o = buf_ready;

    // synthesis translate_off
    wire _unused = &{1'b0, px_x, px_y, frame_start};
    // synthesis translate_on

endmodule
