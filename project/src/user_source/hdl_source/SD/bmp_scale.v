//=============================================================================
// bmp_scale.v — 预载阶段 BMP 双线性缩放（任意尺寸 → 640×480）
//-----------------------------------------------------------------------------
// 设计目标：
//   1) 只在开机预载时工作，不进入运行期像素通路；
//   2) 输入 24-bit、非压缩、bottom-up BMP 的源像素流；
//   3) 输出固定 640×480、RGB888，右侧/上下补黑边保持比例；
//   4) 640×480 源图走逐像素旁路，保证与 M2 完全一致；
//   5) 双线性插值，8-bit 小数权重；离线缩放，不要求 1 pixel/clock。
//
// 数据流：
//   src_valid/src_data ──> 1024×24 源 FIFO
//                            │
//                            ▼
//                     行缓冲 A/B（2048×24，乒乓）
//                            │
//                            ▼
//              双线性插值 + 黑边 → out_valid/out_data
//
// 坐标：
//   源 BMP 为 bottom-up：src row 0 = 显示底部。
//   输出按 SDRAM 写地址顺序 wy=0..479 产生；frame_read_write 的
//   WRITE_V_FLIP=1 会把 wy 翻成显示行 479-wy，所以方向正确。
//
// 资源：
//   2 × line_buffer (2048×24) = 12 BRAM9K
//   1 × 1024×24 FIFO          = 3 BRAM9K（显式 PDPW，不用分布式 RAM）
//   6 个 8×8 乘法器（3 通道 × 水平/垂直各 1 次），综合后 7 DSP
//   全片（含缩放）：LUT 7,243 / BRAM9K 43 / DSP 11
//
// 吞吐：11 拍/像素，离线缩放，单张 640×480 约 30~40ms。
//
// 时钟/复位：clk = 100MHz（sd_card_clk 域），rst 高有效。
// src_config 为单拍脉冲：bmp_read 解析完文件头后给出，用于锁存 W/H。
//=============================================================================
`timescale 1ns / 1ps

module bmp_scale #(
    parameter integer DST_W      = 640,
    parameter integer DST_H      = 480,
    parameter integer MAX_SRC_W  = 1920,
    parameter integer MAX_SRC_H  = 1080,
    parameter integer ADDR_BITS  = 11,
    parameter integer FIFO_AW    = 10
)(
    input  wire        clk,
    input  wire        rst,

    // 源像素流（来自 bmp_read）
    input  wire        src_valid,
    input  wire [23:0] src_data,
    input  wire        src_config,     // 单拍：新图配置，W/H 有效
    input  wire [15:0] src_width,
    input  wire [15:0] src_height,

    // 输出到 frame_read_write
    output wire        out_valid,
    output wire [23:0] out_data,
    output wire        out_done,

    // 源端反压：FIFO 高水位时拉低，bmp_read 在扇区边界暂停
    output wire        src_ready
);

    localparam integer PIXELS = DST_W * DST_H;

    //---------------------------------------------------------------------
    // 配置 / 缩放系数
    //---------------------------------------------------------------------
    reg  [15:0] W, H;
    reg  [15:0] DW, DH;
    reg  [15:0] OX, OY;
    reg  [15:0] x_end, y_end;
    reg  [31:0] x_step, y_step;
    reg         bypass;
    reg         cfg_done;

    // 除法器
    reg         div_start;
    reg  [31:0] div_num, div_den;
    wire [31:0] div_q;
    wire        div_done;

    bmp_div_seq u_div (
        .clk   (clk),
        .rst   (rst),
        .start (div_start),
        .num   (div_num),
        .den   (div_den),
        .q     (div_q),
        .done  (div_done)
    );

    localparam S_IDLE = 3'd0;
    localparam S_DIV1  = 3'd1;
    localparam S_DIV1B = 3'd5;
    localparam S_DIV2  = 3'd2;
    localparam S_DIV3  = 3'd3;
    localparam S_DONE  = 3'd4;

    reg [2:0]  setup_state;
    reg        div_mode;          // 0: width-limited (DW=640), 1: height-limited (DH=480)
    reg [15:0] dw_tmp, dh_tmp;

    wire [31:0] prod_h640 = {16'd0, src_height} * 32'd640;
    wire [31:0] prod_w480 = {16'd0, src_width}  * 32'd480;
    wire        width_limited = (prod_w480 >= prod_h640);

    // div_q 有效时的 DW/DH 组合值（避免在同一个 always 里用未更新的 dw_tmp）
    wire [15:0] div_q16 = (div_q > 32'd65535) ? 16'hFFFF : div_q[15:0];
    wire [15:0] dw_c = div_mode
                     ? ((div_q16 > DST_W) ? DST_W : ((div_q16 == 0) ? 16'd1 : div_q16))
                     : DST_W;
    wire [15:0] dh_c = div_mode
                     ? DST_H
                     : ((div_q16 > DST_H) ? DST_H : ((div_q16 == 0) ? 16'd1 : div_q16));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            W <= 16'd0;
            H <= 16'd0;
            DW <= 16'd0;
            DH <= 16'd0;
            OX <= 16'd0;
            OY <= 16'd0;
            x_end <= 16'd0;
            y_end <= 16'd0;
            x_step <= 32'd0;
            y_step <= 32'd0;
            bypass <= 1'b0;
            cfg_done <= 1'b0;
            setup_state <= S_IDLE;
            div_start <= 1'b0;
            div_num <= 32'd0;
            div_den <= 32'd0;
            div_mode <= 1'b0;
            dw_tmp <= 16'd0;
            dh_tmp <= 16'd0;
        end else if (src_config) begin
            W <= (src_width  == 16'd0) ? 16'd1 : src_width;
            H <= (src_height == 16'd0) ? 16'd1 : src_height;
            DW <= 16'd0;
            DH <= 16'd0;
            OX <= 16'd0;
            OY <= 16'd0;
            x_end <= 16'd0;
            y_end <= 16'd0;
            x_step <= 32'd0;
            y_step <= 32'd0;
            cfg_done <= 1'b0;
            div_mode <= ~width_limited;
            bypass <= (src_width == DST_W) && (src_height == DST_H);

            if ((src_width == DST_W) && (src_height == DST_H)) begin
                DW <= DST_W;
                DH <= DST_H;
                x_end <= DST_W;
                y_end <= DST_H;
                cfg_done <= 1'b1;
                setup_state <= S_IDLE;
                div_start <= 1'b0;
            end else if (width_limited) begin
                // DW = 640, DH = H*640/W
                div_num <= {16'd0, src_height} * 32'd640;
                div_den <= {16'd0, src_width};
                div_start <= 1'b1;
                setup_state <= S_DIV1;
            end else begin
                // DH = 480, DW = W*480/H
                div_num <= {16'd0, src_width} * 32'd480;
                div_den <= {16'd0, src_height};
                div_start <= 1'b1;
                setup_state <= S_DIV1;
            end
        end else begin
            div_start <= 1'b0;

            case (setup_state)
                S_DIV1: begin
                    // 只把 div_q 的结果锁存成 dw_tmp/dh_tmp；
                    // 后续 16bit 比较/减法/加法放下一个状态，避免 q→div_num 长路径。
                    if (div_done) begin
                        dw_tmp <= dw_c;
                        dh_tmp <= dh_c;
                        setup_state <= S_DIV1B;
                    end
                end

                S_DIV1B: begin
                    DW <= dw_tmp;
                    DH <= dh_tmp;
                    OX <= (DST_W - dw_tmp) >> 1;
                    OY <= (DST_H - dh_tmp) >> 1;
                    x_end <= (DST_W + dw_tmp) >> 1;
                    y_end <= (DST_H + dh_tmp) >> 1;

                    if (dw_tmp > 16'd1) begin
                        div_num <= ({16'd0, W} - 32'd1) << 16;
                        div_den <= {16'd0, dw_tmp} - 32'd1;
                        div_start <= 1'b1;
                        setup_state <= S_DIV2;
                    end else begin
                        x_step <= 32'd0;
                        if (dh_tmp > 16'd1) begin
                            div_num <= ({16'd0, H} - 32'd1) << 16;
                            div_den <= {16'd0, dh_tmp} - 32'd1;
                            div_start <= 1'b1;
                            setup_state <= S_DIV3;
                        end else begin
                            y_step <= 32'd0;
                            cfg_done <= 1'b1;
                            setup_state <= S_DONE;
                        end
                    end
                end

                S_DIV2: begin
                    if (div_done) begin
                        x_step <= div_q;
                        if (dh_tmp > 16'd1) begin
                            div_num <= ({16'd0, H} - 32'd1) << 16;
                            div_den <= {16'd0, dh_tmp} - 32'd1;
                            div_start <= 1'b1;
                            setup_state <= S_DIV3;
                        end else begin
                            y_step <= 32'd0;
                            cfg_done <= 1'b1;
                            setup_state <= S_DONE;
                        end
                    end
                end

                S_DIV3: begin
                    if (div_done) begin
                        y_step <= div_q;
                        cfg_done <= 1'b1;
                        setup_state <= S_DONE;
                    end
                end

                S_DONE: begin
                    setup_state <= S_IDLE;
                end

                default: ;
            endcase
        end
    end

    //---------------------------------------------------------------------
    // 1:1 旁路（640×480 源图不经过缩放，保证与 M2 逐像素一致）
    //---------------------------------------------------------------------
    reg        byp_valid;
    reg [23:0] byp_data;
    reg        byp_done;
    reg [18:0] byp_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            byp_valid <= 1'b0;
            byp_data  <= 24'd0;
            byp_done  <= 1'b0;
            byp_cnt   <= 19'd0;
        end else if (src_config) begin
            byp_valid <= 1'b0;
            byp_data  <= 24'd0;
            byp_done  <= 1'b0;
            byp_cnt   <= 19'd0;
        end else begin
            byp_valid <= 1'b0;
            byp_done  <= 1'b0;
            if (bypass && src_valid && (byp_cnt < PIXELS)) begin
                byp_valid <= 1'b1;
                byp_data  <= src_data;
                byp_cnt   <= byp_cnt + 19'd1;
                if (byp_cnt == PIXELS - 1)
                    byp_done <= 1'b1;
            end
        end
    end

    //---------------------------------------------------------------------
    // 源像素 FIFO（1024×24）
    //   SD 读取与缩放输出速率不同；FIFO 只做解耦，
    //   正常情况下不会写满（行缓冲按行消费）。
    //---------------------------------------------------------------------
    reg [FIFO_AW-1:0] fifo_wr_ptr, fifo_rd_ptr;
    reg [FIFO_AW:0]   fifo_cnt;
    wire [23:0]       fifo_dout;
    reg               fifo_rd_en;   // 只由装载器驱动

    wire fifo_full  = (fifo_cnt == (1 << FIFO_AW));
    wire fifo_empty = (fifo_cnt == 0);
    wire fifo_wr    = src_valid && !bypass && !fifo_full;

    // 显式用 PDPW BRAM 做 FIFO 存储，避免综合成 1024×24 分布式 RAM
    line_buffer #(
        .WIDTH     (24),
        .ADDR_BITS (FIFO_AW)
    ) u_fifo (
        .wr_clk  (clk),
        .wr_en   (fifo_wr),
        .wr_addr (fifo_wr_ptr),
        .wr_data (src_data),
        .rd_clk  (clk),
        .rd_addr (fifo_rd_ptr),
        .rd_data (fifo_dout)
    );

    always @(posedge clk) begin
        if (rst || src_config) begin
            fifo_wr_ptr <= {FIFO_AW{1'b0}};
            fifo_rd_ptr <= {FIFO_AW{1'b0}};
            fifo_cnt    <= {(FIFO_AW+1){1'b0}};
        end else begin
            if (fifo_rd_en && !fifo_empty)
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            if (fifo_wr)
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;

            case ({fifo_wr, (fifo_rd_en && !fifo_empty)})
                2'b10: fifo_cnt <= fifo_cnt + 1'b1;
                2'b01: fifo_cnt <= fifo_cnt - 1'b1;
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

    //---------------------------------------------------------------------
    // 行缓冲 A / B（2048×24，显式 EG_LOGIC_BRAM PDPW）
    //   每个缓冲区记录“当前存的是源图第几行”，输出按行号取用；
    //   装载器只在“该行已被输出消费”时才覆盖缓冲区，避免大步长缩小时
    //   “释放早于装载”的竞争（y_step≥2 会死锁）。
    //---------------------------------------------------------------------
    wire       ld_we;
    reg [10:0] ld_row, ld_x;

    reg [10:0] buf_row_a, buf_row_b;
    reg        buf_ready_a, buf_ready_b;

    // 输出侧当前行需要的源行（O_SETUP 锁存）
    reg [15:0] want_y0_r, want_y1_r;
    reg        want_last_r;

    wire [10:0] tgt_row     = ld_row;
    wire        tgt_sel     = ld_row[0];                 // 0=buf A, 1=buf B
    wire [10:0] tgt_row_cur = tgt_sel ? buf_row_b : buf_row_a;
    wire        tgt_ready   = tgt_sel ? buf_ready_b : buf_ready_a;
    wire        tgt_stale   = tgt_ready && (tgt_row_cur < want_y0_r);

    wire        lb_we_a = ld_we && (ld_row[0] == 1'b0);
    wire        lb_we_b = ld_we && (ld_row[0] == 1'b1);
    wire [10:0] lb_waddr_a = ld_x;
    wire [10:0] lb_waddr_b = ld_x;
    wire [23:0] lb_wdata   = fifo_dout;

    reg [10:0]  rd_addr;
    reg         rd_sel0, rd_sel1;  // 0=buf A, 1=buf B

    wire [10:0] lb_raddr_a = (rd_sel0 == 1'b0 || rd_sel1 == 1'b0) ? rd_addr : 11'd0;
    wire [10:0] lb_raddr_b = (rd_sel0 == 1'b1 || rd_sel1 == 1'b1) ? rd_addr : 11'd0;
    wire [23:0] lb_rdata_a, lb_rdata_b;

    line_buffer #(.WIDTH(24), .ADDR_BITS(ADDR_BITS)) u_row_a (
        .wr_clk  (clk),
        .wr_en   (lb_we_a),
        .wr_addr (lb_waddr_a),
        .wr_data (lb_wdata),
        .rd_clk  (clk),
        .rd_addr (lb_raddr_a),
        .rd_data (lb_rdata_a)
    );

    line_buffer #(.WIDTH(24), .ADDR_BITS(ADDR_BITS)) u_row_b (
        .wr_clk  (clk),
        .wr_en   (lb_we_b),
        .wr_addr (lb_waddr_b),
        .wr_data (lb_wdata),
        .rd_clk  (clk),
        .rd_addr (lb_raddr_b),
        .rd_data (lb_rdata_b)
    );

    wire [23:0] rd_data0 = rd_sel0 ? lb_rdata_b : lb_rdata_a;
    wire [23:0] rd_data1 = rd_sel1 ? lb_rdata_b : lb_rdata_a;

    //---------------------------------------------------------------------
    // 源行装载：从 FIFO 取 W 个像素，写入 ld_row[0] 对应的行缓冲
    //---------------------------------------------------------------------
    localparam LD_IDLE = 2'd0;
    localparam LD_RD   = 2'd1;
    localparam LD_WR   = 2'd2;
    reg [1:0] ld_state;

    // 写使能必须与当前 ld_x/fifo_dout 同拍；不能打一拍，
    // 否则地址已经 +1，会把像素写到错位地址。
    assign ld_we = (ld_state == LD_WR);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ld_state   <= LD_IDLE;
            ld_row     <= 11'd0;
            ld_x       <= 11'd0;
            buf_row_a  <= 11'd0;
            buf_row_b  <= 11'd0;
            buf_ready_a<= 1'b0;
            buf_ready_b<= 1'b0;
            fifo_rd_en <= 1'b0;
        end else if (src_config) begin
            ld_state   <= LD_IDLE;
            ld_row     <= 11'd0;
            ld_x       <= 11'd0;
            buf_row_a  <= 11'd0;
            buf_row_b  <= 11'd0;
            buf_ready_a<= 1'b0;
            buf_ready_b<= 1'b0;
            fifo_rd_en <= 1'b0;
        end else begin
            fifo_rd_en <= 1'b0;

            case (ld_state)
                LD_IDLE: begin
                    if (cfg_done && !bypass && (ld_row < H) && !fifo_empty) begin
                        if (tgt_stale) begin
                            // 该缓冲里的行已被输出消费，先释放（下一拍再装）
                            if (tgt_sel) buf_ready_b <= 1'b0;
                            else         buf_ready_a <= 1'b0;
                        end else if (!tgt_ready) begin
                            fifo_rd_en <= 1'b1;
                            ld_state   <= LD_RD;
                        end
                        // tgt_ready && !tgt_stale：该行还要用，等输出推进
                    end
                end

                LD_RD: begin
                    // FIFO 读数据在本拍末有效，下一拍再写行缓冲
                    ld_state <= LD_WR;
                end

                LD_WR: begin
                    ld_state <= LD_IDLE;
                    if (ld_x == W - 1) begin
                        // 整行写完才标记“该缓冲有此行”，避免半行被输出误用
                        if (tgt_sel) begin
                            buf_row_b   <= tgt_row;
                            buf_ready_b <= 1'b1;
                        end else begin
                            buf_row_a   <= tgt_row;
                            buf_ready_a <= 1'b1;
                        end
                        ld_row <= ld_row + 1'b1;
                        ld_x   <= 11'd0;
                    end else begin
                        ld_x <= ld_x + 1'b1;
                    end
                end

                default: ld_state <= LD_IDLE;
            endcase
        end
    end

    //---------------------------------------------------------------------
    // 输出：640×480，逐行产生；bar 像素黑，content 走双线性
    //   11 拍/像素（BRAM 读延迟 1 拍 + 双线性多级流水）：
    //     phase0 设 x0，phase2 采样 x0 + 设 x1，phase4 寄存 x1，
    //     phase5 水平差值，phase6 水平乘，phase7 水平加/舍入，
    //     phase8 垂直差值，phase9 垂直乘，phase10 加/舍入/输出
    //---------------------------------------------------------------------
    localparam O_SETUP = 2'd0;
    localparam O_ROW   = 2'd1;
    localparam O_PIX   = 2'd2;

    reg [1:0]  o_state;
    reg [3:0]  phase;
    reg [9:0]  out_x, out_y;
    reg [31:0] x_acc, y_acc;
    reg [15:0] row_y0, row_y1;
    reg        sel_y0, sel_y1;       // row_y0/row_y1 各在哪个缓冲
    reg [7:0]  row_fx, row_fy;
    reg        row_last;
    reg        bar_row;
    reg        bar_pix;
    reg [23:0] p00, p01;
    reg [23:0] x1_rgb0, x1_rgb1;
    reg signed [10:0] diff_top_r, diff_top_g, diff_top_b;
    reg signed [10:0] diff_bot_r, diff_bot_g, diff_bot_b;
    reg signed [19:0] hprod_top_r, hprod_top_g, hprod_top_b;
    reg signed [19:0] hprod_bot_r, hprod_bot_g, hprod_bot_b;
    reg [23:0] top_rgb, bot_rgb;
    reg signed [10:0] vdiff_r, vdiff_g, vdiff_b;
    reg signed [19:0] vprod_r, vprod_g, vprod_b;
    reg        fsm_valid;
    reg [23:0] fsm_data;
    reg        fsm_done;
    reg        fsm_frame_done;

    // 双线性多级流水：phase5 差值 → phase6 水平乘 → phase7 水平加/舍入
    //                → phase8 垂直差 → phase9 垂直乘 → phase10 加/舍入输出
    // 避免“行缓冲读 → 乘 → 加 → 再乘 → 加”在 100MHz 单拍内串成一条长路径。

    function [7:0] blerp_v_final;
        input [7:0] q0;
        input signed [19:0] m;
        reg signed [10:0] res;
        begin
            res = $signed({1'b0, q0}) + ((m + 20'sd128) >>> 8);
            if (res < 0)
                blerp_v_final = 8'd0;
            else if (res > 255)
                blerp_v_final = 8'd255;
            else
                blerp_v_final = res[7:0];
        end
    endfunction

    wire [15:0] sy_c = y_acc[31:16];
    wire [15:0] sx_c = x_acc[31:16];
    wire [7:0]  fy_c = y_acc[15:8];
    wire [7:0]  fx_c = x_acc[15:8];

    // 最后一行/列强制取源边界，避免定点步进取整导致边缘差 1~2 像素。
    // 用独立计数器代替 out_y-OY / out_x-OX 的 16bit 减法，切断控制长路径。
    reg  [15:0] cy_cnt, cx_cnt;
    wire        last_row_c = (cy_cnt == (DH - 16'd1));
    wire        last_col_c = (cx_cnt == (DW - 16'd1));

    wire [15:0] want_y0 = (last_row_c || (sy_c >= H - 1)) ? (H - 1) : sy_c;
    wire [15:0] want_y1 = (last_row_c || (sy_c >= H - 1)) ? (H - 1) : (sy_c + 1'b1);
    wire        want_last = last_row_c || (sy_c >= H - 1);

    // 行缓冲按“行号”取用：判断需要的两行是否已经在某个缓冲里
    wire y0_in_a = buf_ready_a && (buf_row_a == want_y0_r);
    wire y0_in_b = buf_ready_b && (buf_row_b == want_y0_r);
    wire y1_in_a = buf_ready_a && (buf_row_a == want_y1_r);
    wire y1_in_b = buf_ready_b && (buf_row_b == want_y1_r);
    wire y0_avail = y0_in_a || y0_in_b;
    wire y1_avail = y1_in_a || y1_in_b;
    wire sel0_c   = y0_in_a ? 1'b0 : 1'b1;
    wire sel1_c   = y1_in_a ? 1'b0 : 1'b1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            o_state <= O_SETUP;
            phase   <= 3'd0;
            out_x   <= 10'd0;
            out_y   <= 10'd0;
            cy_cnt  <= 16'd0;
            cx_cnt  <= 16'd0;
            x_acc   <= 32'd0;
            y_acc   <= 32'd0;
            row_y0  <= 16'd0;
            row_y1  <= 16'd0;
            sel_y0  <= 1'b0;
            sel_y1  <= 1'b0;
            want_y0_r  <= 16'd0;
            want_y1_r  <= 16'd0;
            want_last_r <= 1'b0;
            row_fx  <= 8'd0;
            row_fy  <= 8'd0;
            row_last <= 1'b0;
            bar_row <= 1'b0;
            bar_pix <= 1'b0;
            p00     <= 24'd0;
            p01     <= 24'd0;
            x1_rgb0 <= 24'd0;
            x1_rgb1 <= 24'd0;
            diff_top_r <= 11'sd0;
            diff_top_g <= 11'sd0;
            diff_top_b <= 11'sd0;
            diff_bot_r <= 11'sd0;
            diff_bot_g <= 11'sd0;
            diff_bot_b <= 11'sd0;
            hprod_top_r <= 20'sd0;
            hprod_top_g <= 20'sd0;
            hprod_top_b <= 20'sd0;
            hprod_bot_r <= 20'sd0;
            hprod_bot_g <= 20'sd0;
            hprod_bot_b <= 20'sd0;
            top_rgb <= 24'd0;
            bot_rgb <= 24'd0;
            vdiff_r <= 11'sd0;
            vdiff_g <= 11'sd0;
            vdiff_b <= 11'sd0;
            vprod_r <= 20'sd0;
            vprod_g <= 20'sd0;
            vprod_b <= 20'sd0;
            fsm_valid <= 1'b0;
            fsm_data  <= 24'd0;
            fsm_done  <= 1'b0;
            fsm_frame_done <= 1'b0;
        end else if (src_config) begin
            o_state <= O_SETUP;
            phase   <= 3'd0;
            out_x   <= 10'd0;
            out_y   <= 10'd0;
            cy_cnt  <= 16'd0;
            cx_cnt  <= 16'd0;
            x_acc   <= 32'd0;
            y_acc   <= 32'd0;
            row_y0  <= 16'd0;
            row_y1  <= 16'd0;
            sel_y0  <= 1'b0;
            sel_y1  <= 1'b0;
            want_y0_r  <= 16'd0;
            want_y1_r  <= 16'd0;
            want_last_r <= 1'b0;
            row_fx  <= 8'd0;
            row_fy  <= 8'd0;
            row_last <= 1'b0;
            bar_row <= 1'b0;
            bar_pix <= 1'b0;
            p00     <= 24'd0;
            p01     <= 24'd0;
            x1_rgb0 <= 24'd0;
            x1_rgb1 <= 24'd0;
            diff_top_r <= 11'sd0;
            diff_top_g <= 11'sd0;
            diff_top_b <= 11'sd0;
            diff_bot_r <= 11'sd0;
            diff_bot_g <= 11'sd0;
            diff_bot_b <= 11'sd0;
            hprod_top_r <= 20'sd0;
            hprod_top_g <= 20'sd0;
            hprod_top_b <= 20'sd0;
            hprod_bot_r <= 20'sd0;
            hprod_bot_g <= 20'sd0;
            hprod_bot_b <= 20'sd0;
            top_rgb <= 24'd0;
            bot_rgb <= 24'd0;
            vdiff_r <= 11'sd0;
            vdiff_g <= 11'sd0;
            vdiff_b <= 11'sd0;
            vprod_r <= 20'sd0;
            vprod_g <= 20'sd0;
            vprod_b <= 20'sd0;
            fsm_valid <= 1'b0;
            fsm_data  <= 24'd0;
            fsm_done  <= 1'b0;
            fsm_frame_done <= 1'b0;
        end else if (!bypass && cfg_done) begin
            fsm_valid <= 1'b0;
            fsm_done  <= 1'b0;

            if (fsm_frame_done) begin
                // 最后一帧已经输出完，保持静默
            end else begin
                case (o_state)
                O_SETUP: begin
                    // 先把本行的 want/bar 判断打进寄存器，切断 DH/out_y → 控制的长路径
                    if ((out_y < OY) || (out_y >= y_end)) begin
                        bar_row  <= 1'b1;
                        row_last <= 1'b0;
                        bar_pix  <= 1'b1;
                        out_x    <= 10'd0;
                        x_acc    <= 32'd0;
                        cy_cnt   <= 16'd0;
                        cx_cnt   <= 16'd0;
                        phase    <= 3'd0;
                        o_state  <= O_PIX;
                    end else begin
                        bar_row    <= 1'b0;
                        bar_pix    <= 1'b0;
                        want_y0_r  <= want_y0;
                        want_y1_r  <= want_y1;
                        want_last_r <= want_last;
                        row_fy     <= want_last ? 8'd0 : fy_c;
                        out_x      <= 10'd0;
                        x_acc      <= 32'd0;
                        cx_cnt     <= 16'd0;
                        phase      <= 3'd0;
                        o_state    <= O_ROW;
                    end
                end

                O_ROW: begin
                    // 需要的两行是否已经装进行缓冲（按行号判断，不依赖装载顺序）
                    if (y0_avail && y1_avail && !want_last_r) begin
                        row_y0   <= want_y0_r;
                        row_y1   <= want_y1_r;
                        row_last <= 1'b0;
                        sel_y0   <= sel0_c;
                        sel_y1   <= sel1_c;
                        phase    <= 3'd0;
                        o_state  <= O_PIX;
                    end else if (want_last_r && y0_avail) begin
                        row_y0   <= want_y0_r;
                        row_y1   <= want_y0_r;
                        row_last <= 1'b1;
                        sel_y0   <= sel0_c;
                        sel_y1   <= sel0_c;
                        phase    <= 3'd0;
                        o_state  <= O_PIX;
                    end
                end

                O_PIX: begin
                    case (phase)
                        // 0: 设 x0 地址
                        4'd0: begin
                            fsm_valid <= 1'b0;
                            if (bar_row ||
                                (out_x < OX) ||
                                (out_x >= x_end)) begin
                                bar_pix <= 1'b1;
                                phase   <= 4'd10;
                            end else begin
                                bar_pix <= 1'b0;
                                row_fx  <= (last_col_c || (sx_c >= (W - 1))) ? 8'd0 : fx_c;
                                rd_addr <= (last_col_c || (sx_c >= (W - 1)))
                                           ? (W - 1) : sx_c[10:0];
                                rd_sel0 <= sel_y0;
                                rd_sel1 <= row_last ? sel_y0 : sel_y1;
                                phase   <= 4'd1;
                            end
                        end

                        // 1: 等 x0 数据
                        4'd1: phase <= 4'd2;

                        // 2: 采样 p00/p01，设 x1 地址
                        4'd2: begin
                            p00 <= rd_data0;
                            p01 <= rd_data1;
                            rd_addr <= (last_col_c || (sx_c >= (W - 1)))
                                       ? (W - 1)
                                       : (sx_c[10:0] + 11'd1);
                            phase <= 4'd3;
                        end

                        // 3: 等 x1 数据
                        4'd3: phase <= 4'd4;

                        // 4: 先寄存 x1 像素（BRAM 输出直接进寄存器）
                        4'd4: begin
                            if (!bar_pix) begin
                                x1_rgb0 <= rd_data0;
                                x1_rgb1 <= rd_data1;
                            end
                            phase <= 4'd5;
                        end

                        // 5: 水平差值（只做减法）
                        4'd5: begin
                            if (!bar_pix) begin
                                diff_top_r <= $signed({1'b0, x1_rgb0[23:16]}) - $signed({1'b0, p00[23:16]});
                                diff_top_g <= $signed({1'b0, x1_rgb0[15:8]})  - $signed({1'b0, p00[15:8]});
                                diff_top_b <= $signed({1'b0, x1_rgb0[7:0]})   - $signed({1'b0, p00[7:0]});
                                diff_bot_r <= $signed({1'b0, x1_rgb1[23:16]}) - $signed({1'b0, p01[23:16]});
                                diff_bot_g <= $signed({1'b0, x1_rgb1[15:8]})  - $signed({1'b0, p01[15:8]});
                                diff_bot_b <= $signed({1'b0, x1_rgb1[7:0]})   - $signed({1'b0, p01[7:0]});
                            end
                            phase <= 4'd6;
                        end

                        // 6: 水平插值乘法（只做乘法）
                        4'd6: begin
                            if (!bar_pix) begin
                                hprod_top_r <= diff_top_r * $signed({1'b0, row_fx});
                                hprod_top_g <= diff_top_g * $signed({1'b0, row_fx});
                                hprod_top_b <= diff_top_b * $signed({1'b0, row_fx});
                                hprod_bot_r <= diff_bot_r * $signed({1'b0, row_fx});
                                hprod_bot_g <= diff_bot_g * $signed({1'b0, row_fx});
                                hprod_bot_b <= diff_bot_b * $signed({1'b0, row_fx});
                            end
                            phase <= 4'd7;
                        end

                        // 7: 水平插值 加/舍入/饱和
                        4'd7: begin
                            if (!bar_pix) begin
                                top_rgb[23:16] <= blerp_v_final(p00[23:16], hprod_top_r);
                                top_rgb[15:8]  <= blerp_v_final(p00[15:8],  hprod_top_g);
                                top_rgb[7:0]   <= blerp_v_final(p00[7:0],   hprod_top_b);
                                bot_rgb[23:16] <= blerp_v_final(p01[23:16], hprod_bot_r);
                                bot_rgb[15:8]  <= blerp_v_final(p01[15:8],  hprod_bot_g);
                                bot_rgb[7:0]   <= blerp_v_final(p01[7:0],   hprod_bot_b);
                            end
                            phase <= 4'd8;
                        end

                        // 8: 垂直差值
                        4'd8: begin
                            if (!bar_pix) begin
                                vdiff_r <= $signed({1'b0, bot_rgb[23:16]}) - $signed({1'b0, top_rgb[23:16]});
                                vdiff_g <= $signed({1'b0, bot_rgb[15:8]})  - $signed({1'b0, top_rgb[15:8]});
                                vdiff_b <= $signed({1'b0, bot_rgb[7:0]})   - $signed({1'b0, top_rgb[7:0]});
                            end
                            phase <= 4'd9;
                        end

                        // 9: 垂直乘法
                        4'd9: begin
                            if (!bar_pix) begin
                                vprod_r <= vdiff_r * $signed({1'b0, row_fy});
                                vprod_g <= vdiff_g * $signed({1'b0, row_fy});
                                vprod_b <= vdiff_b * $signed({1'b0, row_fy});
                            end
                            phase <= 4'd10;
                        end

                        // 10: 加法/舍入/截断并输出
                        4'd10: begin
                            if (bar_pix) begin
                                fsm_data <= 24'd0;
                            end else begin
                                fsm_data[23:16] <= blerp_v_final(top_rgb[23:16], vprod_r);
                                fsm_data[15:8]  <= blerp_v_final(top_rgb[15:8],  vprod_g);
                                fsm_data[7:0]   <= blerp_v_final(top_rgb[7:0],   vprod_b);
                            end
                            fsm_valid <= 1'b1;
                            if (!bar_pix) begin
                                x_acc <= x_acc + x_step;
                                if (cx_cnt != (DW - 16'd1))
                                    cx_cnt <= cx_cnt + 16'd1;
                            end

                            if (out_x == DST_W - 1) begin
                                out_x  <= 10'd0;
                                cx_cnt <= 16'd0;
                                if (!bar_row) begin
                                    y_acc  <= y_acc + y_step;
                                    cy_cnt <= cy_cnt + 16'd1;
                                end
                                if (out_y == DST_H - 1) begin
                                    fsm_done       <= 1'b1;
                                    fsm_frame_done <= 1'b1;
                                    out_y <= 10'd0;
                                end else begin
                                    out_y <= out_y + 1'b1;
                                end
                                o_state <= O_SETUP;
                            end else begin
                                out_x <= out_x + 1'b1;
                            end
                            phase <= 4'd0;
                        end

                        default: phase <= 4'd0;
                    endcase
                end
            endcase
            end
        end
    end

    //---------------------------------------------------------------------
    // 输出选择：旁路 / 缩放
    //---------------------------------------------------------------------
    assign out_valid = bypass ? byp_valid : fsm_valid;
    assign out_data  = bypass ? byp_data  : fsm_data;
    assign out_done  = bypass ? byp_done  : fsm_done;

    // FIFO 半满即反压，给一个扇区（最多 171 像素）的在途数据留余量
    assign src_ready = bypass ? 1'b1 : (fifo_cnt < (1 << (FIFO_AW - 1)));

    // 未使用信号：保留端口便于调试/后续扩展
    // src_sop/src_eof 由 bmp_read 提供，本模块用 src_config 启动
    // （综合时未连接端口会被优化，不影响功能）

endmodule


//=============================================================================
// bmp_div_seq — 32bit 无符号顺序除法器（32 拍）
//   仅用于每张图开始时的 DW/DH/x_step/y_step 计算；
//   不进入像素通路，面积/时序压力很小。
//=============================================================================
module bmp_div_seq (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] num,
    input  wire [31:0] den,
    output reg  [31:0] q,
    output reg         done
);

    reg        busy;
    reg [5:0]  cnt;
    reg [31:0] rem;
    reg [31:0] quo;
    reg [31:0] num_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy  <= 1'b0;
            cnt   <= 6'd0;
            rem   <= 32'd0;
            quo   <= 32'd0;
            num_r <= 32'd0;
            q     <= 32'd0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start) begin
                if (den == 32'd0) begin
                    q    <= 32'd0;
                    done <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    rem   <= 32'd0;
                    quo   <= 32'd0;
                    num_r <= num;
                    cnt   <= 6'd32;
                    busy  <= 1'b1;
                end
            end else if (busy) begin
                if (cnt == 6'd0) begin
                    q    <= quo;
                    done <= 1'b1;
                    busy <= 1'b0;
                end else begin
                    if ({rem[30:0], num_r[31]} >= den) begin
                        rem <= {rem[30:0], num_r[31]} - den;
                        quo <= {quo[30:0], 1'b1};
                    end else begin
                        rem <= {rem[30:0], num_r[31]};
                        quo <= {quo[30:0], 1'b0};
                    end
                    num_r <= {num_r[30:0], 1'b0};
                    cnt   <= cnt - 1'b1;
                end
            end
        end
    end

endmodule
