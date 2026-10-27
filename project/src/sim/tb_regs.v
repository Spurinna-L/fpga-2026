`timescale 1ns/1ps
//=============================================================================
// tb_regs.v — 16 键寄存器 / 数码管显示值 / 1Hz 时间戳 单元测试
//=============================================================================
module tb_regs;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [15:0] key_deb = 16'd0;
    reg  [3:0]  state_code = 4'd3;
    reg  [1:0]  img_idx = 2'd2;
    reg  [1:0]  disp_buf_idx = 2'd0;

    wire signed [7:0] brightness;
    wire [7:0]  contrast;
    wire [1:0]  trans_mode;
    wire        osd_en;
    wire        subtitle_en;
    wire [1:0]  audio_src;
    wire [1:0]  viz_mode;
    wire [1:0]  timbre;
    wire [7:0]  time_mm, time_ss;
    wire        tick_1hz;
    wire [31:0] seg_value;
    wire [15:0] key_press;

    regs #(
        .SEC_CYCLES (26'd10)          // 加速：每 11 个 50MHz 周期 = 1 “秒”
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .key_deb      (key_deb),
        .state_code   (state_code),
        .img_idx      (img_idx),
        .disp_buf_idx (disp_buf_idx),
        .brightness   (brightness),
        .contrast     (contrast),
        .trans_mode   (trans_mode),
        .osd_en       (osd_en),
        .subtitle_en  (subtitle_en),
        .audio_src    (audio_src),
        .viz_mode     (viz_mode),
        .timbre       (timbre),
        .time_mm      (time_mm),
        .time_ss      (time_ss),
        .tick_1hz     (tick_1hz),
        .seg_value    (seg_value),
        .key_press    (key_press)
    );

    always #10 clk = ~clk;            // 50MHz

    integer errs = 0;
    reg [7:0] ss0;

    task automatic press(input integer k);
        begin
            @(negedge clk);
            key_deb[k] = 1'b1;
            repeat (3) @(negedge clk);
            key_deb[k] = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    task automatic check8(input [7:0] got, input [7:0] exp, input [127:0] name);
        begin
            if (got !== exp) begin
                $display("[TB] FAIL %0s: got=%0d exp=%0d", name, got, exp);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        $display("=== tb_regs start ===");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // 默认值
        check8(brightness, 8'sd0,    "brightness default");
        check8(contrast,   8'd128,   "contrast default");
        check8(trans_mode, 8'd0,     "trans_mode default");
        check8({7'd0, osd_en}, 8'd1, "osd_en default");
        check8({7'd0, subtitle_en}, 8'd1, "subtitle_en default");
        check8({6'd0, audio_src}, 8'd0, "audio_src default");
        check8({6'd0, viz_mode}, 8'd3,  "viz_mode default");

        // 数码管：[SD状态=3][图片号=2][转场/OSD=1][音源/可视化=6]
        if (seg_value[15:12] !== 4'd3) begin $display("[TB] FAIL seg sd=%h", seg_value[15:12]); errs = errs + 1; end
        if (seg_value[11:8]  !== 4'd2) begin $display("[TB] FAIL seg img=%h", seg_value[11:8]); errs = errs + 1; end
        if (seg_value[7:4]   !== 4'h1) begin $display("[TB] FAIL seg mode=%h", seg_value[7:4]); errs = errs + 1; end
        if (seg_value[3:0]   !== 4'h6) begin $display("[TB] FAIL seg aud=%h", seg_value[3:0]); errs = errs + 1; end

        // 亮度 +/-8，饱和到 ±64
        press(4);  check8(brightness, 8'sd8,  "brightness +8");
        press(4);  check8(brightness, 8'sd16, "brightness +16");
        press(5);  check8(brightness, 8'sd8,  "brightness -8");

        // 对比度 +/-16，钳位 64..192
        press(6);  check8(contrast, 8'd144, "contrast +16");
        press(7);  check8(contrast, 8'd128, "contrast -16");

        // 转场 / OSD / 音源 / 可视化
        press(2);  check8(trans_mode, 8'd1, "trans_mode 1");
        press(2);  check8(trans_mode, 8'd2, "trans_mode 2");
        press(2);  check8(trans_mode, 8'd0, "trans_mode wrap");
        press(3);  check8({7'd0, osd_en}, 8'd0, "osd off");
        press(12); check8({7'd0, subtitle_en}, 8'd0, "subtitle off");
        press(12); check8({7'd0, subtitle_en}, 8'd1, "subtitle on");
        press(8);  check8({6'd0, audio_src}, 8'd1, "audio L2");
        press(10); check8({6'd0, viz_mode}, 8'd0, "viz wrap 3->0");

        // 一键复位
        press(11);
        check8(brightness, 8'sd0,  "reset brightness");
        check8(contrast,   8'd128, "reset contrast");
        check8({7'd0, osd_en}, 8'd1, "reset osd");
        check8({7'd0, subtitle_en}, 8'd1, "reset subtitle");
        check8({6'd0, audio_src}, 8'd0, "reset audio");
        check8({6'd0, viz_mode}, 8'd3, "reset viz");

        // 1Hz 时间戳（SEC_CYCLES=10）：相对增量校验（按键过程已走过多秒）
        ss0 = time_ss;
        wait (tick_1hz);
        repeat (2) @(negedge clk);
        check8(time_ss, (ss0 == 8'd59) ? 8'd0 : (ss0 + 8'd1), "time_ss +1");

        ss0 = time_ss;
        wait (tick_1hz);
        repeat (2) @(negedge clk);
        check8(time_ss, (ss0 == 8'd59) ? 8'd0 : (ss0 + 8'd1), "time_ss +2");

        if (errs == 0)
            $display("=== PASS: regs key/seg/timer OK ===");
        else
            $display("=== FAIL: %0d errors ===", errs);

        $finish;
    end

endmodule
