`timescale 1ns/1ps
//=============================================================================
// tb_chain.v — 行读取 + 行缓冲 + mixer 的视频链路联调
//   验证：480 行/帧、first/last_line_done、A/B 切换后的输出颜色
//=============================================================================
module tb_chain;

    reg video_clk = 0;
    always #20 video_clk = ~video_clk;     // 25MHz

    reg ext_mem_clk = 0;
    always #4 ext_mem_clk = ~ext_mem_clk;  // 125MHz

    reg rst_vid = 1, rst_mem = 1;

    // 视频时序
    wire hs_0, vs_0, de_0;
    wire [11:0] v_cnt;
    wire [9:0] pix_x, pix_y;
    wire vs_fall;

    video_timing_data u_timing (
        .video_clk(video_clk), .rst(rst_vid),
        .read_req(), .read_req_ack(1'b0),
        .hs(hs_0), .vs(vs_0), .de(de_0), .v_cnt(v_cnt)
    );

    video_pos u_pos (
        .clk(video_clk), .rst(rst_vid), .vs(vs_0), .de(de_0),
        .x(pix_x), .y(pix_y), .vs_d(), .vs_fall(vs_fall)
    );

    // 行调度
    wire line_toggle, prefetch_zero;
    wire [9:0] line_num;
    line_sched u_sched (
        .clk(video_clk), .rst(rst_vid), .display_valid(1'b1), .v_cnt(v_cnt),
        .line_toggle(line_toggle), .line_num(line_num), .prefetch_zero(prefetch_zero)
    );

    // A/B 控制
    reg [1:0] disp_idx = 0;
    reg [1:0] trans_mode = 0;
    wire [1:0] cur_idx, next_idx, mix_mode;
    wire [7:0] alpha;
    wire [9:0] dx;
    wire trans_active;

    disp_ctrl #(
        .TRANS_FRAMES(4)
    ) u_ctrl (
        .clk(video_clk), .rst(rst_vid), .display_valid(1'b1),
        .disp_idx_in(disp_idx), .trans_mode_in(trans_mode),
        .frame_tick(vs_fall),
        .cur_idx(cur_idx), .next_idx(next_idx), .mix_mode(mix_mode),
        .alpha(alpha), .dx(dx), .trans_active(trans_active)
    );

    // 行读取
    wire line_rd_en;
    wire [20:0] line_rd_addr;
    wire line_busy, line_done, first_line_done, last_line_done;
    wire lb_we, lb_bank, lb_sel;
    wire [9:0] lb_addr;
    wire [23:0] lb_data;
    reg sdr_rd_en = 0;
    reg [31:0] sdr_rd_dout = 0;

    function [20:0] slot_base;
        input [1:0] idx;
        begin
            case (idx)
                2'd0: slot_base = 21'd0;
                2'd1: slot_base = 21'd307200;
                2'd2: slot_base = 21'd614400;
                default: slot_base = 21'd921600;
            endcase
        end
    endfunction

    wire [20:0] base_a = slot_base(cur_idx);
    wire [20:0] base_b = slot_base(next_idx);

    frame_line_read u_reader (
        .clk(ext_mem_clk), .rst(rst_mem), .enable(1'b1),
        .Sdr_init_done(1'b1), .sweep_busy(1'b0),
        .base_a(base_a), .base_b(base_b),
        .line_toggle(line_toggle), .line_num(line_num),
        .line_busy(line_busy), .line_done(line_done),
        .first_line_done(first_line_done), .last_line_done(last_line_done),
        .App_rd_en(line_rd_en), .App_rd_addr(line_rd_addr),
        .Sdr_busy(1'b0), .Sdr_rd_en(sdr_rd_en), .Sdr_rd_dout(sdr_rd_dout),
        .lb_we(lb_we), .lb_bank(lb_bank), .lb_addr(lb_addr),
        .lb_data(lb_data), .lb_sel(lb_sel)
    );

    // SDRAM 行为模型：10 拍返回；A 区红、B 区蓝
    reg [10:0] pv;
    reg [20:0] pa [0:10];
    integer k;
    initial begin
        pv = 0;
        for (k = 0; k <= 10; k = k + 1) pa[k] = 0;
    end
    always @(posedge ext_mem_clk) begin
        for (k = 10; k > 0; k = k - 1) pa[k] <= pa[k-1];
        pa[0] <= line_rd_addr;
        pv <= {pv[9:0], line_rd_en};
        sdr_rd_en <= pv[10];
        if (pa[10] < 21'd307200)
            sdr_rd_dout <= {24'hFF0000, 8'h00};
        else
            sdr_rd_dout <= {24'h0000FF, 8'h00};
    end

    // 行缓冲 + mixer
    wire [23:0] a_data, b_data;
    wire [9:0] a_addr, b_addr;
    wire [23:0] mix_rgb;

    line_buffer u_lb_a (
        .wr_clk(ext_mem_clk), .wr_en(lb_we && !lb_sel),
        .wr_addr({lb_bank, lb_addr}), .wr_data(lb_data),
        .rd_clk(video_clk), .rd_addr({pix_y[0], a_addr}), .rd_data(a_data)
    );
    line_buffer u_lb_b (
        .wr_clk(ext_mem_clk), .wr_en(lb_we && lb_sel),
        .wr_addr({lb_bank, lb_addr}), .wr_data(lb_data),
        .rd_clk(video_clk), .rd_addr({pix_y[0], b_addr}), .rd_data(b_data)
    );

    mixer u_mixer (
        .clk(video_clk), .rst(rst_vid), .x(pix_x), .mode(mix_mode),
        .alpha(alpha), .dx(dx), .a_data(a_data), .b_data(b_data),
        .a_addr(a_addr), .b_addr(b_addr), .rgb(mix_rgb)
    );

    // 边带 2 拍
    wire [22:0] side_in = {hs_0, vs_0, de_0, pix_x, pix_y};
    wire [22:0] side_out;
    video_delay2 #(.WIDTH(23)) u_dly (
        .clk(video_clk), .rst(rst_vid), .din(side_in), .dout(side_out)
    );
    wire post_vs = side_out[21];
    wire post_de = side_out[20];
    wire [9:0] post_x = side_out[19:10];
    wire [9:0] post_y = side_out[9:0];

    // 统计与检查
    integer done_cnt = 0;
    integer first_cnt = 0, last_cnt = 0;
    integer errs = 0;
    integer frame_no = 0;

    always @(posedge ext_mem_clk) begin
        if (line_done) begin
            done_cnt = done_cnt + 1;
            if (lb_bank !== line_num[0]) begin
                if (errs < 5) $display("ERR bank line=%0d bank=%b", line_num, lb_bank);
                errs = errs + 1;
            end
        end
        if (first_line_done) first_cnt = first_cnt + 1;
        if (last_line_done) begin
            last_cnt = last_cnt + 1;
            if (done_cnt < 480) begin
                if (errs < 5) $display("ERR last too early done=%0d", done_cnt);
                errs = errs + 1;
            end
            done_cnt = 0;
        end
    end

    // 空闲时 A=红；切到 B 完成后应为蓝
    integer red_seen = 0, blue_seen = 0;
    always @(posedge video_clk) begin
        if (post_de) begin
            if (mix_rgb == 24'hFF0000) red_seen = red_seen + 1;
            if (mix_rgb == 24'h0000FF) blue_seen = blue_seen + 1;
        end
    end

    initial begin
        repeat (5) @(posedge video_clk);
        rst_vid = 0;
        rst_mem = 0;
        repeat (2) @(posedge video_clk);

        // 等第一帧完成
        wait (last_cnt >= 1);
        repeat (1000) @(posedge video_clk);
        if (first_cnt == 0) begin $display("ERR first_cnt=%0d", first_cnt); errs=errs+1; end
        if (red_seen == 0) begin $display("ERR no red before switch"); errs=errs+1; end

        // 切到 1：溶解（测试用 4 帧转场）
        disp_idx = 2'd1;
        trans_mode = 2'd0;
        wait (last_cnt >= 9);            // 留足同步 + 4 帧转场
        repeat (1000) @(posedge video_clk);
        if (cur_idx !== 2'd1) begin $display("ERR cur_idx=%0d", cur_idx); errs=errs+1; end
        if (blue_seen == 0) begin $display("ERR no blue after dissolve"); errs=errs+1; end
        if (trans_active) begin $display("ERR trans still active"); errs=errs+1; end

        if (errs == 0)
            $display("TB_CHAIN PASS (frames=%0d red=%0d blue=%0d)", last_cnt, red_seen, blue_seen);
        else
            $display("TB_CHAIN FAIL errs=%0d frames=%0d first=%0d red=%0d blue=%0d", errs, last_cnt, first_cnt, red_seen, blue_seen);
        $finish;
    end

    // 超时保护
    initial begin
        #600_000_000;
        $display("TB_CHAIN TIMEOUT last=%0d done=%0d", last_cnt, done_cnt);
        $finish;
    end

endmodule
