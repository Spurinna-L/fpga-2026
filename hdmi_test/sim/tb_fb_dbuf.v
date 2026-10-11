//=============================================================================
// tb_fb_dbuf.v  —  Phase 5 验证：双缓冲换班（带诊断）
//-----------------------------------------------------------------------------
// 验证/诊断：
//   ① 连续几帧的"帧标记色"是否依次变化（换班是否发生）；
//   ② 固定图案区/标记区逐像素比对（错误计数 + 前几处坐标）；
//   ③ front 是否只在非有效像素期变化（无撕裂）；
//   ④ 结束后 dump SDRAM 的 A / B 两块内容 → 判断"写错"还是"读错"。
//=============================================================================
`timescale 1ns / 1ps

module tb_fb_dbuf;

    localparam W = 1280;
    localparam H = 720;
    localparam N = W*H;
    localparam NF = 3;
    localparam A_BASE = 0;
    localparam B_BASE = 921600;

    reg clk_wr = 0, clk_pix = 0, ctrl = 0;
    always #10    clk_wr  = ~clk_wr;
    always #6.667 clk_pix = ~clk_pix;
    always #5     ctrl    = ~ctrl;

    reg rst_n_wr  = 0;
    reg rst_n_pix = 0;

    wire        px_we, frame_done, wr_stall;
    wire [10:0] px_x, px_y;
    wire [15:0] px_pix;
    reg  [7:0]  stub_fid = 0;
    always @(posedge clk_wr) if (frame_done) stub_fid <= stub_fid + 1'b1;

    stub_source #(.W(W), .H(H), .MARK(1)) u_stub (
        .clk(clk_wr), .rst_n(rst_n_wr), .stall(wr_stall),
        .frame_id(stub_fid),
        .px_we(px_we), .px_x(px_x), .px_y(px_y), .px_pix(px_pix),
        .frame_done(frame_done)
    );

    wire [15:0] wr1_data, wr2_data;
    wire        wr1_req, wr2_req, wr1_load, wr2_load, wr1_full, wr2_full;
    wire [20:0] wr1_addr, wr1_max, wr2_addr, wr2_max;
    wire [9:0]  wr1_len, wr2_len;

    wire [15:0] rd1_data, rd2_data;
    wire        rd1_empty, rd2_empty, rd1_req, rd2_req, rd1_load, rd2_load, underrun, front_o;
    wire [20:0] rd1_addr, rd1_max, rd2_addr, rd2_max;
    wire [9:0]  rd1_len, rd2_len;

    wire [15:0] rgb_o;
    wire        de_o, hs_o, vs_o;
    wire        de_i, hs_i, vs_i, frame_start;

    fb_mgr #(.W(W), .H(H)) u_fb (
        .clk_wr(clk_wr), .rst_n_wr(rst_n_wr),
        .px_we(px_we), .px_x(px_x), .px_y(px_y), .px_pix(px_pix),
        .frame_done(frame_done), .wr_stall(wr_stall),
        .wr1_data(wr1_data), .wr1_req(wr1_req), .wr1_addr(wr1_addr),
        .wr1_max_addr(wr1_max), .wr1_length(wr1_len), .wr1_load(wr1_load),
        .wr1_clk(), .wr1_full(wr1_full),
        .wr2_data(wr2_data), .wr2_req(wr2_req), .wr2_addr(wr2_addr),
        .wr2_max_addr(wr2_max), .wr2_length(wr2_len), .wr2_load(wr2_load),
        .wr2_clk(), .wr2_full(wr2_full),
        .clk_pix(clk_pix), .rst_n_pix(rst_n_pix),
        .de_i(de_i), .hs_i(hs_i), .vs_i(vs_i), .frame_start(frame_start),
        .fallback_rgb(16'h0000),
        .rd1_data(rd1_data), .rd1_empty(rd1_empty), .rd1_req(rd1_req),
        .rd1_addr(rd1_addr), .rd1_max_addr(rd1_max), .rd1_length(rd1_len),
        .rd1_load(rd1_load), .rd1_clk(),
        .rd2_data(rd2_data), .rd2_empty(rd2_empty), .rd2_req(rd2_req),
        .rd2_addr(rd2_addr), .rd2_max_addr(rd2_max), .rd2_length(rd2_len),
        .rd2_load(rd2_load), .rd2_clk(),
        .rgb_o(rgb_o), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .underrun(underrun), .front_o(front_o)
    );

    wire [10:0] x, y;
    video_timing_720p u_timing (
        .clk_pix(clk_pix), .rst_n(rst_n_pix),
        .hs(hs_i), .vs(vs_i), .de(de_i), .x(x), .y(y),
        .frame_start(frame_start), .line_start()
    );

    sdram_bhv u_sdram (
        .CTRL_CLK(ctrl), .SDRAM_CLK(ctrl), .RESET_N(rst_n_wr),
        .WR1_DATA(wr1_data), .WR1(wr1_req), .WR1_ADDR(wr1_addr), .WR1_MAX_ADDR(wr1_max),
        .WR1_LENGTH(wr1_len), .WR1_LOAD(wr1_load), .WR1_CLK(clk_wr), .WR1_FULL(wr1_full), .WR1_USE(),
        .WR2_DATA(wr2_data), .WR2(wr2_req), .WR2_ADDR(wr2_addr), .WR2_MAX_ADDR(wr2_max),
        .WR2_LENGTH(wr2_len), .WR2_LOAD(wr2_load), .WR2_CLK(clk_wr), .WR2_FULL(wr2_full), .WR2_USE(),
        .RD1_DATA(rd1_data), .RD1(rd1_req), .RD1_ADDR(rd1_addr), .RD1_MAX_ADDR(rd1_max),
        .RD1_LENGTH(rd1_len), .RD1_LOAD(rd1_load), .RD1_CLK(clk_pix), .RD1_EMPTY(rd1_empty), .RD1_USE(),
        .RD2_DATA(rd2_data), .RD2(rd2_req), .RD2_ADDR(rd2_addr), .RD2_MAX_ADDR(rd2_max),
        .RD2_LENGTH(rd2_len), .RD2_LOAD(rd2_load), .RD2_CLK(clk_pix), .RD2_EMPTY(rd2_empty), .RD2_USE()
    );

    // 基础图案（不含标记）
    function [15:0] pat;
        input integer xx, yy;
        reg [7:0] rr, gg, bb;
        begin
            rr = xx[7:0];  gg = yy[7:0];
            bb = (xx[7] ^ yy[7]) ? 8'hFF : 8'h00;
            if (xx < 4 || xx >= W-4 || yy < 4 || yy >= H-4) pat = 16'hFFFF;
            else pat = {rr[7:3], gg[7:2], bb[7:3]};
        end
    endfunction

    function in_mark; input integer xx, yy;
        in_mark = (xx >= 8) && (xx < 24) && (yy >= 8) && (yy < 24);
    endfunction

    function is_pal; input [15:0] v;
        is_pal = (v === 16'hFFFF) || (v === 16'hF800) ||
                 (v === 16'h07E0) || (v === 16'h001F);
    endfunction

    // 撕裂监测
    reg front_d;
    always @(posedge clk_pix) begin
        front_d <= front_o;
        if (front_o !== front_d && de_i) $display("[tb][撕裂!] front 在有效像素期变化 @ %0t", $time);
    end

    // BMP 输出
    integer fd;
    task bmp_u16; input [15:0] v; begin $fwrite(fd,"%c",v[7:0]); $fwrite(fd,"%c",v[15:8]); end endtask
    task bmp_u32; input [31:0] v; begin $fwrite(fd,"%c",v[7:0]); $fwrite(fd,"%c",v[15:8]); $fwrite(fd,"%c",v[23:16]); $fwrite(fd,"%c",v[31:24]); end endtask
    task bmp_hdr;
        begin
            bmp_u16(16'h4D42); bmp_u32(W*3*H+54); bmp_u32(0); bmp_u32(54);
            bmp_u32(40); bmp_u32(W); bmp_u32(-H);
            bmp_u16(1); bmp_u16(24); bmp_u32(0); bmp_u32(W*3*H);
            bmp_u32(2835); bmp_u32(2835); bmp_u32(0); bmp_u32(0);
        end
    endtask
    task bmp_px; input [15:0] v;
        begin $fwrite(fd,"%c%c%c", {v[4:0],v[4:2]}, {v[10:5],v[10:9]}, {v[15:11],v[15:13]}); end
    endtask

    integer fi, px, e_fix, e_pal, e_x, e_pal_tot, e_fix_tot, e_x_tot;
    integer rlo, rhi;
    reg [15:0] got, markc;
    integer ii;
    reg [15:0] mv;

    initial begin
        #100 rst_n_wr  = 1'b1;
        #100 rst_n_pix = 1'b1;

        @(posedge u_fb.buf_ready);
        $display("[tb] buf_ready=1，开始抓 %0d 个显示帧 ...", NF);

        e_fix_tot = 0; e_pal_tot = 0; e_x_tot = 0;
        for (fi = 0; fi < NF; fi = fi + 1) begin
            e_fix = 0; e_pal = 0; e_x = 0; rlo = 99999; rhi = -1;
            px = 0; markc = 16'hxxxx;
            while (px < N) begin
                @(posedge clk_pix);
                if (de_o) begin
                    got = rgb_o;
                    if (px == 16*W + 16) markc = got;
                    if (got === 16'hxxxx) begin
                        e_x = e_x + 1;
                        if (rlo > px/W) rlo = px/W;
                        if (rhi < px/W) rhi = px/W;
                    end else if (in_mark(px % W, px / W)) begin
                        if (!is_pal(got)) e_pal = e_pal + 1;
                    end else begin
                        if (got !== pat(px % W, px / W)) begin
                            e_fix = e_fix + 1;
                            if (rlo > px/W) rlo = px/W;
                            if (rhi < px/W) rhi = px/W;
                        end
                    end
                    px = px + 1;
                end
            end
            e_fix_tot += e_fix; e_pal_tot += e_pal; e_x_tot += e_x;
            $display("[tb] 帧%0d: mark=%h front=%b | fix=%0d  mark_bad=%0d  x=%0d | 错误行 %0d..%0d",
                     fi, markc, front_o, e_fix, e_pal, e_x, (rhi<0)?0:rlo, (rhi<0)?0:rhi);
        end

        // ---- dump SDRAM 两块内容 ----
        $display("[tb] dump SDRAM A ...");
        fd = $fopen("dbuf_memA.bmp", "wb"); bmp_hdr;
        for (ii = 0; ii < N; ii = ii + 1) bmp_px(u_sdram.mem[A_BASE + ii]);
        $fclose(fd);
        $display("[tb] dump SDRAM B ...");
        fd = $fopen("dbuf_memB.bmp", "wb"); bmp_hdr;
        for (ii = 0; ii < N; ii = ii + 1) bmp_px(u_sdram.mem[B_BASE + ii]);
        $fclose(fd);

        $display("[tb] 合计: fix=%0d  mark_bad=%0d  x=%0d", e_fix_tot, e_pal_tot, e_x_tot);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("[tb] TIMEOUT");
        $finish;
    end

endmodule
