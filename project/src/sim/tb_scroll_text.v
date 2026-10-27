//=============================================================================
// tb_scroll_text.v — 底部中文滚动字幕自检（ModelSim）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) 字库 ROM 抽查（码表 / 行号 / 位序，与生成文件比对）
//   2) 复位后 pos = 640（文本完全在屏幕外）
//   3) vs 帧边界每帧左移 1 像素；关闭字幕时位置冻结
//   4) 字形像素 = 红色 24'hFF0000；字幕带内其余像素 = 纯白 24'hFFFFFF
//   5) 字幕带外 / de=0 / I_en=0 逐像素直通
//   6) 循环回绕：pos = POS_MIN+1 → POS_MIN → 640
//
// 用法（ModelSim）：
//   vlog font_cn_16x16.v scroll_text_overlay.v tb_scroll_text.v
//   vsim -c tb_scroll_text -do "run -all; quit -f"
//=============================================================================
`timescale 1ns/1ps

module tb_scroll_text;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         vs  = 1'b1;

    reg         de  = 1'b0;
    reg  [9:0]  x   = 10'd0;
    reg  [9:0]  y   = 10'd0;
    reg  [23:0] rgb = 24'h123456;
    reg         en  = 1'b1;

    wire        o_de;
    wire [9:0]  o_x, o_y;
    wire [23:0] o_rgb;

    scroll_text_overlay dut (
        .I_clk (clk),
        .I_rst (rst),
        .I_vs  (vs),
        .I_de  (de),
        .I_x   (x),
        .I_y   (y),
        .I_rgb (rgb),
        .I_en  (en),
        .O_de  (o_de),
        .O_x   (o_x),
        .O_y   (o_y),
        .O_rgb (o_rgb)
    );

    // 独立字库实例（用于抽查 ROM 内容 + 计算期望像素）
    reg  [3:0]  ref_code = 4'd0;
    reg  [3:0]  ref_row  = 4'd0;
    wire [15:0] ref_bits;

    font_cn_16x16 u_ref (
        .I_code (ref_code),
        .I_row  (ref_row),
        .O_bits (ref_bits)
    );

    always #20 clk = ~clk;    // 25MHz

    integer errors = 0;
    integer checks = 0;

    localparam [9:0] BAND_Y0 = 10'd444;
    localparam [9:0] BAND_H  = 10'd24;
    localparam [9:0] TEXT_Y0 = 10'd448;
    localparam integer TEXT_W = 11 * 16;
    localparam signed [11:0] POS_MIN = -(TEXT_W + 64);

    //-------------------------------------------------------------------------
    // 单像素比较
    //-------------------------------------------------------------------------
    task automatic check_px;
        input [9:0] px;
        input [9:0] py;

        reg        in_band;
        reg        in_row;
        integer    dx;
        reg [3:0]  ch_i;
        reg [3:0]  col_i;
        reg [23:0] exp;
        begin
            x = px;
            y = py;
            #1;

            checks = checks + 1;

            in_band = (py >= BAND_Y0) && (py < (BAND_Y0 + BAND_H));
            in_row  = (py >= TEXT_Y0) && (py < (TEXT_Y0 + 10'd16));
            dx      = px - dut.pos;

            ch_i   = dx[7:4];
            col_i  = dx[3:0];

            ref_code = ch_i;
            ref_row  = py - TEXT_Y0;
            #1;   // 等组合字库稳定

            if (!en || !de || !in_band)
                exp = rgb;
            else if (in_row && (dx >= 0) && (dx < TEXT_W) &&
                     ref_bits[15 - col_i])
                exp = 24'hFF0000;   // 字形：红色
            else
                exp = 24'hFFFFFF;   // 底条：纯白

            if (o_rgb !== exp) begin
                errors = errors + 1;
                $display("FAIL px(%0d,%0d) pos=%0d: got %06x exp %06x",
                         px, py, dut.pos, o_rgb, exp);
            end
            if (o_de !== de || o_x !== px || o_y !== py) begin
                errors = errors + 1;
                $display("FAIL sideband px(%0d,%0d): de=%b x=%0d y=%0d",
                         px, py, o_de, o_x, o_y);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // vs 帧边界脉冲
    //-------------------------------------------------------------------------
    task automatic vs_pulse;
        begin
            @(negedge clk);
            vs = 1'b0;
            @(negedge clk);
            vs = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    //-------------------------------------------------------------------------
    // ROM 抽查
    //-------------------------------------------------------------------------
    task automatic check_rom;
        input [3:0]  code;
        input [3:0]  row;
        input [15:0] exp;
        begin
            ref_code = code;
            ref_row  = row;
            #1;
            checks = checks + 1;
            if (ref_bits !== exp) begin
                errors = errors + 1;
                $display("FAIL ROM[%0d][%0d]: got %04x exp %04x",
                         code, row, ref_bits, exp);
            end
        end
    endtask

    integer i;
    reg signed [11:0] pos_save;

    initial begin
        $display("=== tb_scroll_text start ===");

        de  = 1'b1;
        x   = 10'd0;
        y   = 10'd0;
        rgb = 24'h123456;
        en  = 1'b1;

        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // ---- 1) 字库 ROM 抽查（与 font_cn_16x16.v 生成内容一致）----
        check_rom(4'd0,  4'd6,  16'b1111000010110000);  // 逐 · 第 6 行
        check_rom(4'd5,  4'd11, 16'b0011000000000000);  // ，· 第 11 行
        check_rom(4'd10, 4'd0,  16'b0001000001000000);  // 约 · 第 0 行

        // ---- 2) 复位后 pos = 640，文本完全在屏幕外 ----
        checks = checks + 1;
        if (dut.pos !== 12'sd640) begin
            errors = errors + 1;
            $display("FAIL reset pos: got %0d exp 640", dut.pos);
        end
        check_px(10'd639, 10'd454);   // 屏幕最右像素也应是白底
        check_px(10'd0,   10'd454);

        // ---- 3) 一帧后 pos = 639；文本第 0 列进入屏幕最右列 ----
        vs_pulse;
        checks = checks + 1;
        if (dut.pos !== 12'sd639) begin
            errors = errors + 1;
            $display("FAIL pos after 1 frame: got %0d exp 639", dut.pos);
        end
        // 逐第 6 行 bit15 = 1 → (639, 454) 是字形像素（红色）
        check_px(10'd639, 10'd454);
        // 再往左一格已无文本 → 白底
        check_px(10'd638, 10'd454);
        // 第 0 行 bit15 = 0 → 白底
        check_px(10'd639, 10'd448);

        // ---- 4) 指定 pos 做系统像素检查 ----
        dut.pos = 12'sd100;
        #1;

        check_px(10'd103, 10'd454);   // 逐 · row6 · col3 → bit12=1 → 红字
        check_px(10'd100, 10'd454);   // col0 → bit15=0 → 白底
        check_px(10'd181, 10'd459);   // ，· row11 · col1 → bit14=1 → 红字
        check_px(10'd263, 10'd448);   // 约 · row0 · col3 → bit12=1 → 红字
        check_px(10'd275, 10'd448);   // 约 · row0 · col15 → bit0=0 → 白底

        // 字幕带内、文本之外仍是白底
        check_px(10'd10,  10'd444);
        check_px(10'd10,  10'd467);
        // 字幕带上下边界外必须直通
        check_px(10'd10,  10'd443);
        check_px(10'd10,  10'd468);
        // de=0 直通（即使落在字形上）
        de = 1'b0;
        check_px(10'd103, 10'd454);
        de = 1'b1;

        // ---- 5) 关闭字幕：完全直通 + 位置冻结 ----
        en = 1'b1;
        vs_pulse;                     // pos 100 → 99
        pos_save = dut.pos;
        en = 1'b0;
        check_px(10'd10, 10'd454);    // 带内也直通
        check_px(10'd103, 10'd454);   // 字形位置也直通
        repeat (5) vs_pulse;          // 关字幕期间不应滚动
        checks = checks + 1;
        if (dut.pos !== pos_save) begin
            errors = errors + 1;
            $display("FAIL pos frozen: got %0d exp %0d", dut.pos, pos_save);
        end
        en = 1'b1;

        // ---- 6) 循环回绕 ----
        dut.pos = POS_MIN + 12'sd1;   // -239
        #1;
        vs_pulse;                     // → -240
        checks = checks + 1;
        if (dut.pos !== POS_MIN) begin
            errors = errors + 1;
            $display("FAIL pos wrap end: got %0d exp %0d", dut.pos, POS_MIN);
        end
        vs_pulse;                     // → 640
        checks = checks + 1;
        if (dut.pos !== 12'sd640) begin
            errors = errors + 1;
            $display("FAIL pos wrap start: got %0d exp 640", dut.pos);
        end

        // ---- 7) 全帧扫描：pos=100 时逐像素对齐检查（抽行）----
        dut.pos = 12'sd100;
        #1;
        for (i = 0; i < 640; i = i + 7)
            check_px(i[9:0], 10'd448);
        for (i = 0; i < 640; i = i + 7)
            check_px(i[9:0], 10'd454);

        $display("=== tb_scroll_text done: %0d checks, %0d errors ===",
                 checks, errors);
        if (errors != 0)
            $display("RESULT: FAIL");
        else
            $display("RESULT: PASS");
        $finish;
    end

endmodule
