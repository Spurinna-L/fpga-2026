`timescale 1ns / 1ps
// 音频链路快速验证：测试音 → I2S 接收 → PCM/ACR
// 20ms 内期望：audio_valid ≈ 960（48kHz），acr_valid ≈ 20
module tb_audio;
    reg mclk = 0;
    reg clk  = 0;
    reg rst  = 1;

    wire        bclk, lrck, dout;
    wire        audio_valid;
    wire [23:0] audio_l, audio_r;
    wire        acr_valid;
    wire [19:0] acr_cts, acr_n;

    hdmi_audio_tone_i2s_64fs #(
        .PHASE_INC (32'd39370534),
        .AMP       (24'sd2000000)
    ) u_tone (
        .I_mclk       (mclk),
        .I_rst        (rst),
        .I_use_ext    (1'b0),          // 本 TB 只验证 L1 内部音阶
        .I_ext_sample (24'sd0),
        .O_i2s_BCLK (bclk),
        .O_i2s_LRCK (lrck),
        .O_i2s_DOUT (dout)
    );

    I2S_receiver u_rx (
        .I_clk              (clk),
        .I_rst              (rst),
        .I_i2s_BCLK         (bclk),
        .I_i2s_LRCK         (lrck),
        .I_i2s_DOUT         (dout),
        .O_audio_valid      (audio_valid),
        .O_audio_left_data  (audio_l),
        .O_audio_right_data (audio_r)
    );

    audio_arc_calculate #(
        .ACR_N (6144)
    ) u_acr (
        .I_clk         (clk),
        .I_rst         (rst),
        .I_audio_valid (audio_valid),
        .O_acr_valid   (acr_valid),
        .O_acr_cts     (acr_cts),
        .O_acr_n       (acr_n)
    );

    always #40.69 mclk = ~mclk; // 12.288MHz
    always #20    clk  = ~clk;  // 25MHz

    integer valid_cnt = 0;
    integer acr_cnt   = 0;
    reg [19:0] acr_n_seen = 20'd0;

    always @(posedge clk) begin
        if (audio_valid) valid_cnt <= valid_cnt + 1;
        if (acr_valid) begin
            acr_cnt   <= acr_cnt + 1;
            acr_n_seen <= acr_n;
        end
    end

    initial begin
        rst = 1;
        #1000;
        rst = 0;
        #20_000_000; // 20ms
        $display("audio_valid=%0d (expect ~960), acr_valid=%0d (expect ~20)", valid_cnt, acr_cnt);
        $display("last L=%0d R=%0d cts=%0d n=%0d", $signed(audio_l), $signed(audio_r), acr_cts, acr_n);
        $display("acr_n captured at acr_valid = %0d", acr_n_seen);
        if ((valid_cnt < 900) || (valid_cnt > 1020) ||
            (acr_cnt   < 15)  || (acr_cnt   > 25)   ||
            (acr_n_seen !== 20'd6144)) begin
            $display("tb_audio: FAIL");
        end else begin
            $display("tb_audio: PASS");
        end
        $finish;
    end
endmodule
