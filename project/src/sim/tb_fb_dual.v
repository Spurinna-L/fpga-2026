`timescale 1ns/1ps
//=============================================================================
// tb_fb_dual.v — frame_read_write_dual A/B 双读验证
//-----------------------------------------------------------------------------
// 目的（M1 验收）：
//   1. 写通道把两份图案分别写入 BUF0 / BUF1（保留 WRITE_V_FLIP 行倒序）；
//   2. 读通道 A/B 同时读，共用 read_en，验证像素严格锁步；
//   3. 验证 A 只读 BUF0、B 只读 BUF1，且各自读满一帧；
//   4. 验证 125MHz 读突发仲裁没有串道/丢数/饿死。
//
// 为了仿真速度，测试帧缩小为 64×16（1024 像素），但地址生成、V_FLIP、
// 突发仲裁与 FIFO 通路与 640×480 完全一致。
//=============================================================================
module tb_fb_dual;

    parameter integer W      = 64;
    parameter integer H      = 16;
    localparam integer PIXELS = W * H;          // 默认 1024
    localparam integer BUF1     = PIXELS;         // 1024
    localparam integer ADDR_BITS = 21;
    localparam [ADDR_BITS-1:0] PIXELS_A = PIXELS;
    localparam [ADDR_BITS-1:0] BUF1_A   = BUF1;

    // 可由 -P tb_fb_dual.SDRAM_LATENCY=24 覆盖，用来验证仲裁对长读延迟的鲁棒性
    parameter integer SDRAM_LATENCY = 3;
    parameter integer PASSES        = 2;

    localparam [31:0] TAG_A = 32'hA000_0000;
    localparam [31:0] TAG_B = 32'hB000_0000;

    //-------------------------------------------------------------------------
    // 时钟 / 复位
    //-------------------------------------------------------------------------
    reg mem_clk   = 1'b0;
    reg write_clk = 1'b0;
    reg read_clk  = 1'b0;
    reg rst       = 1'b1;

    always #4  mem_clk   = ~mem_clk;     // 125MHz
    always #5  write_clk = ~write_clk;   // 100MHz
    always #20 read_clk  = ~read_clk;    // 25MHz

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    wire                  App_rd_en;
    wire [ADDR_BITS-1:0]  App_rd_addr;
    wire                  Sdr_rd_en;
    wire [31:0]           Sdr_rd_dout;

    wire                  App_wr_en;
    wire [ADDR_BITS-1:0]  App_wr_addr;
    wire [31:0]           App_wr_din;
    wire [3:0]            App_wr_dm;

    wire                  Sdr_init_done;
    wire                  Sdr_init_ref_vld;
    wire                  Sdr_busy;

    reg                   write_req       = 1'b0;
    wire                  write_req_ack;
    wire                  write_finish;
    reg  [ADDR_BITS-1:0]  write_len       = PIXELS;
    reg                   write_en        = 1'b0;
    reg  [31:0]           write_data      = 32'd0;
    reg  [1:0]            write_addr_index = 2'd0;

    reg                   read_req        = 1'b0;
    wire                  read_req_ack;
    wire                  read_finish;
    reg                   read_en         = 1'b0;
    wire [31:0]           read_data_a;
    wire [31:0]           read_data_b;
    wire                  read_empty_a;
    wire                  read_empty_b;

    frame_read_write_dual #(
        .ADDR_BITS     (ADDR_BITS),
        .BURST_SIZE    (128),
        .WRITE_V_FLIP  (1),
        .FRAME_WIDTH   (W),
        .FRAME_HEIGHT  (H)
    ) dut (
        .rst              (rst),
        .mem_clk          (mem_clk),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy),

        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout),

        .read_clk         (read_clk),
        .read_req         (read_req),
        .read_req_ack     (read_req_ack),
        .read_finish      (read_finish),
        .read_base_a      (21'd0),
        .read_base_b      (BUF1_A),
        .read_len         (PIXELS_A),
        .read_en          (read_en),
        .read_data_a      (read_data_a),
        .read_data_b      (read_data_b),
        .read_empty_a     (read_empty_a),
        .read_empty_b     (read_empty_b),
        .single_a         (1'b0),

        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_din       (App_wr_din),
        .App_wr_dm        (App_wr_dm),

        .write_clk        (write_clk),
        .write_req        (write_req),
        .write_req_ack    (write_req_ack),
        .write_finish     (write_finish),
        .write_addr_0     (21'd0),
        .write_addr_1     (BUF1_A),
        .write_addr_2     (21'd0),
        .write_addr_3     (21'd0),
        .write_addr_index (write_addr_index),
        .write_len        (write_len),
        .write_en         (write_en),
        .write_data       (write_data)
    );

    sdram_bhv #(
        .ADDR_BITS (ADDR_BITS),
        .DATA_BITS (32),
        .LATENCY   (SDRAM_LATENCY)
    ) u_sdram (
        .clk              (mem_clk),
        .rst              (rst),
        .App_wr_en        (App_wr_en),
        .App_wr_addr      (App_wr_addr),
        .App_wr_din       (App_wr_din),
        .App_wr_dm        (App_wr_dm),
        .App_rd_en        (App_rd_en),
        .App_rd_addr      (App_rd_addr),
        .Sdr_rd_en        (Sdr_rd_en),
        .Sdr_rd_dout      (Sdr_rd_dout),
        .Sdr_init_done    (Sdr_init_done),
        .Sdr_init_ref_vld (Sdr_init_ref_vld),
        .Sdr_busy         (Sdr_busy)
    );

    //-------------------------------------------------------------------------
    // 读地址范围统计：A 必须落在 [0,1023]，B 必须落在 [1024,2047]
    //-------------------------------------------------------------------------
    integer n_rd_a = 0;
    integer n_rd_b = 0;
    integer n_rd_bad = 0;
    reg     read_finished = 1'b0;

    always @(posedge mem_clk)
        if (read_finish)
            read_finished <= 1'b1;

    always @(posedge mem_clk) begin
        if (App_rd_en) begin
            if (App_rd_addr < PIXELS)
                n_rd_a <= n_rd_a + 1;
            else if (App_rd_addr < (2 * PIXELS))
                n_rd_b <= n_rd_b + 1;
            else
                n_rd_bad <= n_rd_bad + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 任务
    //-------------------------------------------------------------------------
    task automatic write_frame(input [1:0] idx, input [31:0] tag);
        integer n;
        begin
            @(negedge write_clk);
            write_addr_index = idx;
            write_req        = 1'b1;

            @(negedge write_clk);
            while (!write_req_ack)
                @(negedge write_clk);
            write_req = 1'b0;

            // 等 FIFO 清空/状态机进入 CHECK_FIFO
            repeat (30) @(negedge write_clk);

            for (n = 0; n < PIXELS; n = n + 1) begin
                write_en   = 1'b1;
                write_data = tag | n[31:0];
                @(negedge write_clk);
            end
            write_en = 1'b0;

            @(posedge write_finish);
            repeat (5) @(negedge write_clk);
            $display("[TB] write_frame idx=%0d tag=%h done", idx, tag);
        end
    endtask

    task automatic start_read;
        begin
            @(negedge mem_clk);
            read_req = 1'b1;
            repeat (20) @(negedge mem_clk);   // 160ns，足够 3 级同步
            read_req = 1'b0;
        end
    endtask

    function automatic [31:0] expect_word(input [31:0] tag, input integer j);
        integer row, col, src;
        begin
            row = j / W;
            col = j % W;
            src = (H - 1 - row) * W + col;    // 写侧 V_FLIP 的行倒序
            expect_word = tag | src;
        end
    endfunction

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer j;
    integer pass;
    integer errs;
    integer total_errs;
    reg [31:0] exp_a, exp_b;
    reg        done = 1'b0;

    initial begin
        $display("=== tb_fb_dual start (frame %0dx%0d, 2 passes) ===", W, H);

        repeat (10) @(negedge mem_clk);
        rst = 1'b0;

        wait (Sdr_init_done);
        repeat (5) @(negedge mem_clk);

        write_frame(2'd0, TAG_A);
        write_frame(2'd1, TAG_B);

        total_errs = 0;

        // 连续两次“整帧读”，覆盖 vs 重启 / FIFO 异步清空路径
        for (pass = 0; pass < PASSES; pass = pass + 1) begin
            start_read();

            // 等两路 FIFO 预取到高水位
            #20000;

            errs = 0;
            @(negedge read_clk);
            read_en = 1'b1;

            for (j = 0; j < PIXELS; j = j + 1) begin
                @(negedge read_clk);
                exp_a = expect_word(TAG_A, j);
                exp_b = expect_word(TAG_B, j);
                if (read_data_a !== exp_a) begin
                    if (errs < 10)
                        $display("[TB] pass%0d MISMATCH A j=%0d got=%h exp=%h", pass, j, read_data_a, exp_a);
                    errs = errs + 1;
                end
                if (read_data_b !== exp_b) begin
                    if (errs < 10)
                        $display("[TB] pass%0d MISMATCH B j=%0d got=%h exp=%h", pass, j, read_data_b, exp_b);
                    errs = errs + 1;
                end
            end
            read_en = 1'b0;
            total_errs = total_errs + errs;

            // 等到两路都读满本帧
            begin : wait_cnt
                integer t;
                for (t = 0; t < 20000; t = t + 1) begin
                    if ((n_rd_a >= (pass + 1) * PIXELS) && (n_rd_b >= (pass + 1) * PIXELS))
                        disable wait_cnt;
                    @(negedge read_clk);
                end
                $display("[TB] pass%0d WARN: read counter timeout (A=%0d B=%0d)", pass, n_rd_a, n_rd_b);
            end

            repeat (50) @(negedge read_clk);
            $display("[TB] pass%0d done: errs=%0d A=%0d B=%0d", pass, errs, n_rd_a, n_rd_b);
        end

        $display("[TB] read addr count: A=%0d B=%0d bad=%0d", n_rd_a, n_rd_b, n_rd_bad);
        $display("[TB] total lockstep data errors: %0d", total_errs);
        $display("[TB] read_finish seen: %0d", read_finished);

        if ((total_errs == 0) && (n_rd_a == PASSES * PIXELS) && (n_rd_b == PASSES * PIXELS) &&
            (n_rd_bad == 0) && read_finished)
            $display("=== PASS: A/B dual read OK (2 frames, lockstep, no cross-talk) ===");
        else
            $display("=== FAIL: errs=%0d a=%0d b=%0d bad=%0d fin=%0d ===",
                     total_errs, n_rd_a, n_rd_b, n_rd_bad, read_finished);

        done = 1'b1;
        $finish;
    end

    // 看门狗：两次写 + PASSES 次读，约 2*PIXELS*10ns + PASSES*PIXELS*40ns，留足余量
    initial begin
        #(2 * PIXELS * 10 + PASSES * PIXELS * 40 + 3_000_000);
        if (!done) begin
            $display("=== FAIL: TIMEOUT (n_rd_a=%0d n_rd_b=%0d) ===", n_rd_a, n_rd_b);
            $finish;
        end
    end

endmodule
