//=============================================================================
// tb_param_latch.v — video_param_latch 自检（ModelSim）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) 复位默认值 = BRT:+00 / CNT:128 / IMG:1 / TR:0（与 regs.v 复位一致）
//   2) 参数变化但未到 vs 帧边界时，输出保持不变（画面不会中途撕裂）
//   3) vs 下降沿 + 总线稳定 → 整组锁存，且十进制拆分正确
//   4) 亮度符号：负数 → '-'，非负 → '+'
//   5) 参数刚变化（稳定计数未满）就遇到 vs → 本次不锁存
//
// 用法（ModelSim）：
//   vlog video_param_latch.v tb_param_latch.v
//   vsim -c tb_param_latch -do "run -all; quit"
//=============================================================================
`timescale 1ns / 1ps

module tb_param_latch;

    reg               clk = 1'b0;
    reg               rst = 1'b1;
    reg               vs  = 1'b1;

    reg  signed [7:0] br  = 8'sd0;
    reg  [7:0]        cnt = 8'd128;
    reg               en  = 1'b1;
    reg               sub = 1'b1;
    reg  [1:0]        trm = 2'd0;
    reg  [1:0]        img = 2'd0;
    reg  [7:0]        mm  = 8'd0;
    reg  [7:0]        ss  = 8'd0;
    reg  [2:0]        fx  = 3'd0;   // 风格化滤镜模式（K14）

    wire signed [7:0] o_br;
    wire [7:0]        o_cnt;
    wire              o_en;
    wire              o_sub;
    wire [1:0]        o_trm;

    wire [4:0] o_sign, o_bh, o_bl, o_ch, o_cm, o_cl;
    wire [4:0] o_mmh, o_mml, o_ssh, o_ssl, o_img, o_tr;
    wire [2:0] o_fxm;
    wire [4:0] o_fxch;

    video_param_latch dut (
        .I_clk        (clk),
        .I_rst        (rst),
        .I_vs         (vs),
        .I_brightness (br),
        .I_contrast   (cnt),
        .I_osd_en     (en),
        .I_subtitle_en(sub),
        .I_trans_mode (trm),
        .I_img_idx    (img),
        .I_time_mm    (mm),
        .I_time_ss    (ss),
        .I_viz_mode   (2'd0),
        .I_fx_mode    (fx),
        .O_brightness (o_br),
        .O_contrast   (o_cnt),
        .O_osd_en     (o_en),
        .O_subtitle_en(o_sub),
        .O_trans_mode (o_trm),
        .O_ch_brt_sign(o_sign),
        .O_ch_brt_hi  (o_bh),
        .O_ch_brt_lo  (o_bl),
        .O_ch_cnt_h   (o_ch),
        .O_ch_cnt_m   (o_cm),
        .O_ch_cnt_l   (o_cl),
        .O_ch_mm_hi   (o_mmh),
        .O_ch_mm_lo   (o_mml),
        .O_ch_ss_hi   (o_ssh),
        .O_ch_ss_lo   (o_ssl),
        .O_ch_img     (o_img),
        .O_ch_tr      (o_tr),
        .O_fx_mode    (o_fxm),
        .O_ch_fx      (o_fxch)
    );

    always #20 clk = ~clk;    // 25MHz

    integer errors = 0;
    integer checks = 0;

    // 12 个字符码 + 4 个参数值，打包成一个向量比较
    wire [59:0] obs_ch = {o_sign, o_bh, o_bl, o_ch, o_cm, o_cl,
                          o_mmh, o_mml, o_ssh, o_ssl, o_img, o_tr};
    wire [18:0] obs_prm = {o_br, o_cnt, o_en, o_sub, o_trm};

    reg [59:0] exp_ch;
    reg [18:0] exp_prm;

    task expect_ch;
        input [4:0] sign, bh, bl, ch, cm, cl;
        input [4:0] mmh, mml, ssh, ssl, im, tr;
        begin
            exp_ch = {sign, bh, bl, ch, cm, cl, mmh, mml, ssh, ssl, im, tr};
        end
    endtask

    task vs_pulse;
        begin
            @(negedge clk);
            vs = 1'b0;
            @(negedge clk);
            vs = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    task compare;
        input [255:0] tag;
        begin
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (obs_ch !== exp_ch) begin
                errors = errors + 1;
                $display("FAIL [%0s] chars: got %015x exp %015x", tag, obs_ch, exp_ch);
                $display("        got sign=%0d %0d%0d | cnt=%0d%0d%0d | mm=%0d%0d ss=%0d%0d | img=%0d tr=%0d",
                         o_sign, o_bh, o_bl, o_ch, o_cm, o_cl, o_mmh, o_mml, o_ssh, o_ssl, o_img, o_tr);
            end
            if (obs_prm !== exp_prm) begin
                errors = errors + 1;
                $display("FAIL [%0s] prm: got brt=%0d cnt=%0d en=%b sub=%b trm=%0d", tag,
                         o_br, o_cnt, o_en, o_sub, o_trm);
            end
        end
    endtask

    initial begin
        //---------------------------------------------------------------------
        // 1) 复位默认值
        //---------------------------------------------------------------------
        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        expect_ch(5'd12, 5'd0, 5'd0, 5'd1, 5'd2, 5'd8, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd0);
        exp_prm = {8'sd0, 8'd128, 1'b1, 1'b1, 2'd0};
        compare("reset default");

        //---------------------------------------------------------------------
        // 2) 参数变化但未到 vs → 输出必须保持旧值
        //---------------------------------------------------------------------
        @(negedge clk);
        br  = -8'sd8;
        cnt = 8'd64;
        en  = 1'b0;
        trm = 2'd2;
        img = 2'd3;
        mm  = 8'd9;
        ss  = 8'd59;

        repeat (40) @(posedge clk);
        compare("no vs = hold");

        //---------------------------------------------------------------------
        // 3) vs 下降沿 + 稳定 → 锁存
        //    brt=-8 → '-' 0 8 ; cnt=64 → 0 6 4 ; mm=9 → 0 9 ; ss=59 → 5 9
        //    img=3 → '4'(code 4) ; tr=2 → '2'(code 2)
        //---------------------------------------------------------------------
        vs_pulse;
        expect_ch(5'd13, 5'd0, 5'd8, 5'd0, 5'd6, 5'd4, 5'd0, 5'd9, 5'd5, 5'd9, 5'd4, 5'd2);
        exp_prm = {-8'sd8, 8'd64, 1'b0, 1'b1, 2'd2};
        compare("latch #1");

        //---------------------------------------------------------------------
        // 4) 再换一组：br=+64 / cnt=192 / img=0 / tr=1 / mm=0 / ss=0
        //---------------------------------------------------------------------
        @(negedge clk);
        br  = 8'sd64;
        cnt = 8'd192;
        en  = 1'b1;
        trm = 2'd1;
        img = 2'd0;
        mm  = 8'd0;
        ss  = 8'd0;

        repeat (40) @(posedge clk);
        compare("no vs = hold #2");

        vs_pulse;
        expect_ch(5'd12, 5'd6, 5'd4, 5'd1, 5'd9, 5'd2, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1);
        exp_prm = {8'sd64, 8'd192, 1'b1, 1'b1, 2'd1};
        compare("latch #2");

        //---------------------------------------------------------------------
        // 5) 刚改完参数（稳定计数未满）就遇到 vs → 本次不锁存
        //---------------------------------------------------------------------
        @(negedge clk);
        br  = -8'sd64;
        repeat (2) @(negedge clk);       // 只过 2 个周期，远小于 STABLE_N=8
        vs = 1'b0;
        @(negedge clk);
        vs = 1'b1;
        repeat (10) @(posedge clk);
        compare("unstable vs ignored");

        //---------------------------------------------------------------------
        // 6) 等稳定后再 vs → 正常锁存 brt=-64 → '-' 6 4
        //---------------------------------------------------------------------
        repeat (20) @(posedge clk);
        vs_pulse;
        expect_ch(5'd13, 5'd6, 5'd4, 5'd1, 5'd9, 5'd2, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1);
        exp_prm = {-8'sd64, 8'd192, 1'b1, 1'b1, 2'd1};
        compare("latch #3");

        //---------------------------------------------------------------------
        // 7) 对比度边界：cnt=0 → 0 0 0；cnt=255 → 2 5 5
        //---------------------------------------------------------------------
        @(negedge clk);
        cnt = 8'd0;
        repeat (20) @(posedge clk);
        vs_pulse;
        expect_ch(5'd13, 5'd6, 5'd4, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1);
        exp_prm = {-8'sd64, 8'd0, 1'b1, 1'b1, 2'd1};
        compare("cnt=0");

        @(negedge clk);
        cnt = 8'd255;
        repeat (20) @(posedge clk);
        vs_pulse;
        expect_ch(5'd13, 5'd6, 5'd4, 5'd2, 5'd5, 5'd5, 5'd0, 5'd0, 5'd0, 5'd0, 5'd1, 5'd1);
        exp_prm = {-8'sd64, 8'd255, 1'b1, 1'b1, 2'd1};
        compare("cnt=255");

        //---------------------------------------------------------------------
        // 8) 字幕开关（K13）单独跨域：其他参数不变，仅 sub 1 → 0 → 1
        //---------------------------------------------------------------------
        @(negedge clk);
        sub = 1'b0;
        repeat (20) @(posedge clk);
        vs_pulse;
        exp_prm = {-8'sd64, 8'd255, 1'b1, 1'b0, 2'd1};
        compare("subtitle off");

        @(negedge clk);
        sub = 1'b1;
        repeat (20) @(posedge clk);
        vs_pulse;
        exp_prm = {-8'sd64, 8'd255, 1'b1, 1'b1, 2'd1};
        compare("subtitle on");

        //---------------------------------------------------------------------
        // 9) 滤镜模式（K14）：帧边界整组锁存，O_ch_fx = {2'b00, O_fx_mode}
        //---------------------------------------------------------------------
        @(negedge clk);
        fx = 3'd5;
        repeat (20) @(posedge clk);
        vs_pulse;
        checks = checks + 1;
        if ((o_fxm !== 3'd5) || (o_fxch !== 5'd5)) begin
            errors = errors + 1;
            $display("FAIL fx latch: o_fxm=%0d o_fxch=%0d exp 5/5", o_fxm, o_fxch);
        end

        @(negedge clk);
        fx = 3'd7;
        repeat (20) @(posedge clk);
        vs_pulse;
        checks = checks + 1;
        if ((o_fxm !== 3'd7) || (o_fxch !== 5'd7)) begin
            errors = errors + 1;
            $display("FAIL fx latch #2: o_fxm=%0d o_fxch=%0d exp 7/7", o_fxm, o_fxch);
        end

        $display("--------------------------------------------------");
        $display("tb_param_latch: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("tb_param_latch: PASS");
        else
            $display("tb_param_latch: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
