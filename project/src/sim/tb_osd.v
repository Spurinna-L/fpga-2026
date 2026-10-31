//=============================================================================
// tb_osd.v — osd_composer 自检（ModelSim）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) I_en=0 时逐像素完全直通（合入 OSD 前的画面不能被改动）
//   2) 面板矩形之外（含消隐期）逐像素完全直通
//   3) 面板内：字形像素 = 0xFFFFFF，非字形像素 = 每通道右移 1 位
//   4) 行间 2px 空隙不画字（直通）
//   5) 排版表位置正确：逐像素与「独立字库实例 + 独立排版函数」对照
//      （3 行 20 列全扫，含第 3 行的滤镜模式 F0..F7）
//
// 用法（ModelSim）：
//   vlog font_ascii_8x16.v osd_composer.v tb_osd.v
//   vsim -c tb_osd -do "run -all; quit"
//=============================================================================
`timescale 1ns / 1ps

module tb_osd;

    //-------------------------------------------------------------------------
    // DUT 输入
    //-------------------------------------------------------------------------
    reg         en = 1'b1;
    reg         de = 1'b1;
    reg  [9:0]  x  = 10'd0;
    reg  [9:0]  y  = 10'd0;
    reg  [23:0] rgb = 24'h12_34_56;

    reg  [4:0]  i_brt_sign = 5'd12;   // '+'
    reg  [4:0]  i_brt_hi   = 5'd0;
    reg  [4:0]  i_brt_lo   = 5'd8;
    reg  [4:0]  i_cnt_h    = 5'd1;
    reg  [4:0]  i_cnt_m    = 5'd2;
    reg  [4:0]  i_cnt_l    = 5'd8;
    reg  [4:0]  i_mm_hi    = 5'd0;
    reg  [4:0]  i_mm_lo    = 5'd5;
    reg  [4:0]  i_ss_hi    = 5'd4;
    reg  [4:0]  i_ss_lo    = 5'd2;
    reg  [4:0]  i_img      = 5'd1;
    reg  [4:0]  i_tr       = 5'd0;
    reg  [4:0]  i_fx       = 5'd1;
    reg  [4:0]  i_viz      = 5'd3;    // viz_mode = 2'b11 -> 字符 '3'
    reg  [4:0]  i_tmb      = 5'd1;
    reg  [4:0]  i_src      = 5'd0;

    wire        o_de;
    wire [9:0]  o_x, o_y;
    wire [23:0] o_rgb;

    osd_composer dut (
        .I_de       (de),
        .I_x        (x),
        .I_y        (y),
        .I_rgb      (rgb),
        .I_en       (en),
        .I_brt_sign (i_brt_sign),
        .I_brt_hi   (i_brt_hi),
        .I_brt_lo   (i_brt_lo),
        .I_cnt_h    (i_cnt_h),
        .I_cnt_m    (i_cnt_m),
        .I_cnt_l    (i_cnt_l),
        .I_mm_hi    (i_mm_hi),
        .I_mm_lo    (i_mm_lo),
        .I_ss_hi    (i_ss_hi),
        .I_ss_lo    (i_ss_lo),
        .I_img      (i_img),
        .I_tr       (i_tr),
        .I_fx       (i_fx),
        .I_viz_mode (i_viz),
        .I_timbre   (i_tmb),
        .I_audio_src(i_src),
        .O_de       (o_de),
        .O_x        (o_x),
        .O_y        (o_y),
        .O_rgb      (o_rgb)
    );

    //-------------------------------------------------------------------------
    // 独立字库实例：用来算「期望点阵」，避免在 tb 里复制 512 项 case 表
    //-------------------------------------------------------------------------
    reg  [4:0] probe_code = 5'd14;
    reg  [3:0] probe_row  = 4'd0;
    wire [7:0] probe_bits;

    font_ascii_8x16 u_probe (
        .I_code (probe_code),
        .I_row  (probe_row),
        .O_bits (probe_bits)
    );

    integer errors = 0;
    integer checks = 0;

    //-------------------------------------------------------------------------
    // 排版表（必须与 osd_composer.v 完全一致）
    //-------------------------------------------------------------------------
    function [4:0] calc_ch;
        input integer col;
        input integer line_idx;          // 0=第1行 1=第2行 2=第3行
        begin
            calc_ch = 5'd14;                 // 空格
            if (line_idx == 0) begin
                case (col)
                    0 : calc_ch = 5'd15;     // T
                    1 : calc_ch = 5'd16;     // I
                    2 : calc_ch = 5'd17;     // M
                    3 : calc_ch = 5'd18;     // E
                    4 : calc_ch = 5'd14;     // SP
                    5 : calc_ch = i_mm_hi;
                    6 : calc_ch = i_mm_lo;
                    7 : calc_ch = 5'd10;     // :
                    8 : calc_ch = i_ss_hi;
                    9 : calc_ch = i_ss_lo;
                    10: calc_ch = 5'd14;     // SP
                    11: calc_ch = 5'd16;     // I
                    12: calc_ch = 5'd17;     // M
                    13: calc_ch = 5'd23;     // G
                    14: calc_ch = 5'd10;     // :
                    15: calc_ch = i_img;
                    16: calc_ch = 5'd11;     // /
                    17: calc_ch = 5'd4;      // '4'
                    default: calc_ch = 5'd14;
                endcase
            end else if (line_idx == 1) begin
                case (col)
                    0 : calc_ch = 5'd19;     // B
                    1 : calc_ch = 5'd20;     // R
                    2 : calc_ch = 5'd15;     // T
                    3 : calc_ch = 5'd10;     // :
                    4 : calc_ch = i_brt_sign;
                    5 : calc_ch = i_brt_hi;
                    6 : calc_ch = i_brt_lo;
                    7 : calc_ch = 5'd14;     // SP
                    8 : calc_ch = 5'd21;     // C
                    9 : calc_ch = 5'd22;     // N
                    10: calc_ch = 5'd15;     // T
                    11: calc_ch = 5'd10;     // :
                    12: calc_ch = i_cnt_h;
                    13: calc_ch = i_cnt_m;
                    14: calc_ch = i_cnt_l;
                    15: calc_ch = 5'd14;     // SP
                    16: calc_ch = 5'd15;     // T
                    17: calc_ch = 5'd20;     // R
                    18: calc_ch = 5'd10;     // :
                    19: calc_ch = i_tr;
                    default: calc_ch = 5'd14;
                endcase
            end else begin
                // 第 3 行：MDE:1 TMB:1 SRC:0 F1
                case (col)
                    0 : calc_ch = 5'd17;     // M
                    1 : calc_ch = 5'd26;     // D
                    2 : calc_ch = 5'd18;     // E
                    3 : calc_ch = 5'd10;     // :
                    4 : calc_ch = i_viz;
                    5 : calc_ch = 5'd14;     // SP
                    6 : calc_ch = 5'd15;     // T
                    7 : calc_ch = 5'd17;     // M
                    8 : calc_ch = 5'd19;     // B
                    9 : calc_ch = 5'd10;     // :
                    10: calc_ch = i_tmb;
                    11: calc_ch = 5'd14;     // SP
                    12: calc_ch = 5'd27;     // S
                    13: calc_ch = 5'd20;     // R
                    14: calc_ch = 5'd21;     // C
                    15: calc_ch = 5'd10;     // :
                    16: calc_ch = i_src;
                    17: calc_ch = 5'd14;     // SP
                    18: calc_ch = 5'd25;     // F
                    19: calc_ch = i_fx;
                    default: calc_ch = 5'd14;
                endcase
            end
        end
    endfunction

    // 每个通道右移 1 位（与 RTL 的 bg_half 一致）
    function [7:0] half8;
        input [7:0] v;
        begin
            half8 = {1'b0, v[7:1]};
        end
    endfunction

    //-------------------------------------------------------------------------
    // 逐点检查
    //-------------------------------------------------------------------------
    integer xx, yy;
    integer dx, dy, col, row5, subx, line_idx;
    reg     in_panel, in_row;
    reg [23:0] exp_rgb;

    task check_point;
        begin
            dx = xx - 472;
            dy = yy - 8;
            col  = (dx >> 3) & 31;
            subx = dx & 7;
            line_idx = (dy >= 36) ? 2 : ((dy >= 18) ? 1 : 0);
            row5  = dy - line_idx * 18;

            in_panel = (de == 1'b1) && (dx >= 0) && (dx < 160) && (dy >= 0) && (dy < 52);
            in_row   = (row5 >= 0) && (row5 < 16);

            // 驱动 DUT 与探针
            x = xx[9:0];
            y = yy[9:0];
            if (in_row) begin
                probe_code = calc_ch(col, line_idx);
                probe_row  = row5[3:0];
            end else begin
                probe_code = 5'd14;
                probe_row  = 4'd0;
            end

            #1;

            if (!en || !in_panel || !in_row)
                exp_rgb = rgb;
            else if (probe_bits[7 - subx])
                exp_rgb = 24'hFFFFFF;
            else
                exp_rgb = {half8(rgb[23:16]), half8(rgb[15:8]), half8(rgb[7:0])};

            checks = checks + 1;
            if (o_rgb !== exp_rgb) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL (%0d,%0d) de=%b en=%b in_panel=%b col=%0d row=%0d subx=%0d glyph=%02x got=%06x exp=%06x",
                             xx, yy, de, en, in_panel, col, row5, subx, probe_bits,
                             o_rgb, exp_rgb);
            end
            if (o_de !== de || o_x !== xx[9:0] || o_y !== yy[9:0]) begin
                errors = errors + 1;
                $display("FAIL passthrough de/x/y at (%0d,%0d)", xx, yy);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        en = 1'b1;
        de = 1'b1;
        rgb = 24'h12_34_56;

        //---------------------------------------------------------------------
        // 1) 面板及其周边逐像素扫描（含左右上下边界、行间空隙）
        //---------------------------------------------------------------------
        for (yy = 0; yy < 60; yy = yy + 1)
            for (xx = 455; xx < 640; xx = xx + 1)
                check_point;

        //---------------------------------------------------------------------
        // 2) 面板外远处抽样
        //---------------------------------------------------------------------
        for (yy = 100; yy < 480; yy = yy + 37)
            for (xx = 0; xx < 455; xx = xx + 29)
                check_point;

        //---------------------------------------------------------------------
        // 3) 换一组参数再扫一遍（验证排版表取的是「当前参数」）
        //---------------------------------------------------------------------
        i_brt_sign = 5'd13;   // '-'
        i_brt_hi   = 5'd6;
        i_brt_lo   = 5'd4;
        i_cnt_h    = 5'd0;
        i_cnt_m    = 5'd6;
        i_cnt_l    = 5'd4;
        i_mm_hi    = 5'd9;
        i_mm_lo    = 5'd9;
        i_ss_hi    = 5'd5;
        i_ss_lo    = 5'd9;
        i_img      = 5'd4;
        i_tr       = 5'd2;
        i_fx       = 5'd7;
        i_viz      = 5'd0;
        i_tmb      = 5'd2;
        i_src      = 5'd1;
        rgb        = 24'hFE_DC_BA;

        for (yy = 0; yy < 50; yy = yy + 1)
            for (xx = 465; xx < 640; xx = xx + 1)
                check_point;

        //---------------------------------------------------------------------
        // 4) I_en=0 必须严格直通（含面板内）
        //---------------------------------------------------------------------
        en = 1'b0;
        for (yy = 0; yy < 50; yy = yy + 1)
            for (xx = 465; xx < 640; xx = xx + 1)
                check_point;

        //---------------------------------------------------------------------
        // 5) de=0 必须严格直通（消隐期不能被改写）
        //---------------------------------------------------------------------
        en = 1'b1;
        de = 1'b0;
        for (yy = 0; yy < 50; yy = yy + 1)
            for (xx = 465; xx < 640; xx = xx + 1)
                check_point;

        //---------------------------------------------------------------------
        // 6) 字形确实画出来了：第 1 行 'T' 区域应存在白像素
        //---------------------------------------------------------------------
        begin : glyph_present
            integer white_cnt;
            en = 1'b1;
            de = 1'b1;
            white_cnt = 0;
            for (yy = 8; yy < 24; yy = yy + 1) begin
                for (xx = 472; xx < 480; xx = xx + 1) begin
                    x = xx[9:0];
                    y = yy[9:0];
                    #1;
                    if (o_rgb === 24'hFFFFFF)
                        white_cnt = white_cnt + 1;
                end
            end
            checks = checks + 1;
            if (white_cnt == 0) begin
                errors = errors + 1;
                $display("FAIL glyph 'T' all background, white_cnt=0");
            end
        end

        $display("--------------------------------------------------");
        $display("tb_osd: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("tb_osd: PASS");
        else
            $display("tb_osd: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
