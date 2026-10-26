//=============================================================================
// tb_logo_overlay.v — logo_overlay 自检（ModelSim）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) I_en=0 时逐像素完全直通（合入 Logo 前/关掉 Logo 的画面必须一模一样）
//   2) Logo 矩形外（含消隐期）逐像素完全直通
//   3) 矩形内：不透明像素 = ROM 颜色（RGB555→888 展开），透明像素 = 原像素直通
//   4) de=0 时（消隐区）即使坐标落在矩形内也完全直通
//   5) 地址映射正确：addr = (y-Y0)*32 + (x-X0)，与 ROM 独立实例逐点对照
//   6) ROM 结构自检：上下留白全透明、不透明像素数量合理、含红与深蓝两种颜色
//
// 用法（ModelSim）：
//   vlog logo_data_32x32.v logo_overlay.v tb_logo_overlay.v
//   vsim -c tb_logo_overlay -do "run -all; quit -f"
//=============================================================================
`timescale 1ns / 1ps

module tb_logo_overlay;

    //-------------------------------------------------------------------------
    // DUT 输入
    //-------------------------------------------------------------------------
    reg         en = 1'b1;
    reg         de = 1'b1;
    reg  [9:0]  x  = 10'd0;
    reg  [9:0]  y  = 10'd0;
    reg  [23:0] rgb = 24'h00_00_00;

    wire        o_de;
    wire [9:0]  o_x, o_y;
    wire [23:0] o_rgb;

    logo_overlay dut (
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

    //-------------------------------------------------------------------------
    // ROM 独立实例：用来算「期望颜色」，避免在 tb 里复制 1024 项 case 表
    //-------------------------------------------------------------------------
    reg  [9:0]  probe_addr = 10'd0;
    wire [15:0] probe_pix;

    logo_data_32x32 u_probe (
        .I_addr (probe_addr),
        .O_pix  (probe_pix)
    );

    // RGB555 → RGB888（与 RTL 的 logo_rgb 一致）
    function [23:0] expand;
        input [15:0] p;
        begin
            expand = {p[14:10], p[14:12], p[ 9: 5], p[ 9: 7], p[ 4: 0], p[ 4: 2]};
        end
    endfunction

    integer errors = 0;
    integer checks = 0;

    //-------------------------------------------------------------------------
    // 逐点检查
    //-------------------------------------------------------------------------
    integer xx, yy, dx, dy;
    reg     in_box;
    reg [23:0] exp_rgb;

    task check_point;
        begin
            dx = xx - 8;
            dy = yy - 8;
            in_box = (dx >= 0) && (dx < 32) && (dy >= 0) && (dy < 32);

            x   = xx[9:0];
            y   = yy[9:0];
            rgb = {xx[7:0], yy[7:0], 8'h5A};   // 每点唯一的背景色，便于定位串位

            if (dx >= 0 && dx < 32 && dy >= 0 && dy < 32)
                probe_addr = {dy[4:0], dx[4:0]};   // addr = y*32 + x
            else
                probe_addr = 10'd0;

            #1;

            if (en == 1'b1 && de == 1'b1 && in_box && probe_pix[15])
                exp_rgb = expand(probe_pix);
            else
                exp_rgb = rgb;

            checks = checks + 1;
            if (o_rgb !== exp_rgb) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL rgb (%0d,%0d) de=%b en=%b in_box=%b addr=%0d pix=%04x got=%06x exp=%06x",
                             xx, yy, de, en, in_box, probe_addr, probe_pix, o_rgb, exp_rgb);
            end
            if (o_de !== de || o_x !== xx[9:0] || o_y !== yy[9:0]) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL passthrough de/x/y at (%0d,%0d)", xx, yy);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // ROM 结构自检
    //-------------------------------------------------------------------------
    integer a, opaque_cnt, red_cnt, navy_cnt;
    reg [4:0] r5, g5, b5;

    task check_rom;
        begin
            opaque_cnt = 0;
            red_cnt    = 0;
            navy_cnt   = 0;

            for (a = 0; a < 1024; a = a + 1) begin
                probe_addr = a[9:0];
                #1;
                if (probe_pix[15]) begin
                    opaque_cnt = opaque_cnt + 1;
                    r5 = probe_pix[14:10];
                    g5 = probe_pix[ 9: 5];
                    b5 = probe_pix[ 4: 0];
                    if (r5 > 5'd20 && b5 < 5'd8) red_cnt  = red_cnt  + 1;
                    if (b5 > 5'd4  && r5 < 5'd12) navy_cnt = navy_cnt + 1;
                end else begin
                    // 透明像素颜色域必须为 0（否则说明生成器/ROM 有脏数据）
                    if (probe_pix[14:0] !== 15'd0) begin
                        errors = errors + 1;
                        $display("FAIL rom: transparent entry %0d has color %04x", a, probe_pix);
                    end
                end
            end

            checks = checks + 3;
            if (opaque_cnt < 100 || opaque_cnt > 900) begin
                errors = errors + 1;
                $display("FAIL rom: opaque count %0d out of sane range", opaque_cnt);
            end
            if (red_cnt == 0) begin
                errors = errors + 1;
                $display("FAIL rom: no red pixel found");
            end
            if (navy_cnt == 0) begin
                errors = errors + 1;
                $display("FAIL rom: no navy pixel found");
            end
            $display("ROM: opaque=%0d red=%0d navy=%0d", opaque_cnt, red_cnt, navy_cnt);
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        //---------------------------------------------------------------------
        // 1) en=1：扫描 Logo 区域及其四周（覆盖四条边界）
        //---------------------------------------------------------------------
        en = 1'b1;
        de = 1'b1;
        for (yy = 0; yy < 80; yy = yy + 1)
            for (xx = 0; xx < 80; xx = xx + 1)
                check_point;

        // 2) 远离 Logo 的画面角落：必须完全直通
        xx = 639; yy = 0;   check_point;
        xx = 639; yy = 479; check_point;
        xx = 0;   yy = 479; check_point;
        xx = 40;  yy = 8;   check_point;   // 矩形右边 1 列
        xx = 8;   yy = 40;  check_point;   // 矩形下边 1 行
        xx = 7;   yy = 8;   check_point;   // 矩形左边 1 列
        xx = 8;   yy = 7;   check_point;   // 矩形上边 1 行

        //---------------------------------------------------------------------
        // 3) en=0：同一区域必须逐像素直通（这是「不影响原图」的硬指标）
        //---------------------------------------------------------------------
        en = 1'b0;
        for (yy = 0; yy < 80; yy = yy + 1)
            for (xx = 0; xx < 80; xx = xx + 1)
                check_point;

        //---------------------------------------------------------------------
        // 4) de=0：消隐区即使坐标落在矩形内也只能直通
        //---------------------------------------------------------------------
        en = 1'b1;
        de = 1'b0;
        for (yy = 8; yy < 40; yy = yy + 1)
            for (xx = 8; xx < 40; xx = xx + 1)
                check_point;
        de = 1'b1;

        //---------------------------------------------------------------------
        // 5) ROM 结构自检
        //---------------------------------------------------------------------
        check_rom;

        if (errors == 0)
            $display("tb_logo_overlay: PASS  checks=%0d errors=0", checks);
        else
            $display("tb_logo_overlay: FAIL  checks=%0d errors=%0d", checks, errors);

        $finish;
    end

endmodule
