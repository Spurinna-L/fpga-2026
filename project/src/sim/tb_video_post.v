`timescale 1ns / 1ps
//=============================================================================
// tb_video_post.v — video_post 自检（iverilog / ModelSim 通用）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) 亮度 0 / 对比度 128 / 滤镜直通时，rgb/hs/vs/de/x/y 全部严格延迟 6 拍后原样输出；
//   2) 亮度 +8 / -8 生效，且 0/255 两端饱和不环绕；
//   3) 对比度 64 / 192 方向正确（暗的更暗、亮的更亮）；
//   4) hs/vs 与像素同一延迟，不会出现同步头错位。
//=============================================================================

module tb_video_post;

    reg               clk = 1'b0;
    reg               rst = 1'b1;

    reg  [23:0]       rgb_in = 24'd0;
    reg               hs_in  = 1'b1;
    reg               vs_in  = 1'b1;
    reg               de_in  = 1'b0;
    reg  [9:0]        x_in   = 10'd0;
    reg  [9:0]        y_in   = 10'd0;
    reg  signed [7:0] br     = 8'sd0;
    reg  [7:0]        ct     = 8'd128;
    reg               osd_en = 1'b0;   // 本测试关闭 OSD/Logo，验证逐像素直通
    reg               subtitle_en = 1'b0;
    reg  [2:0]        fx_mode = 3'd0;  // 滤镜直通

    wire [23:0] rgb_out;
    wire        hs_out, vs_out, de_out;
    wire [9:0]  x_out, y_out;

    video_post dut (
        .clk        (clk),
        .rst        (rst),
        .rgb_in     (rgb_in),
        .hs_in      (hs_in),
        .vs_in      (vs_in),
        .de_in      (de_in),
        .x_in       (x_in),
        .y_in       (y_in),
        .brightness (br),
        .contrast   (ct),
        .osd_en     (osd_en),
        .subtitle_en(subtitle_en),
        .time_mm    (8'd0),
        .time_ss    (8'd0),
        .img_idx    (2'd0),
        .trans_mode (2'd0),
        .audio_src  (2'd0),
        .audio_timbre(2'd0),
        .viz_mode   (2'd0),
        .fx_mode    (fx_mode),
        .audio_valid(1'b0),
        .audio_sample(24'sd0),
        .rgb_out    (rgb_out),
        .hs_out     (hs_out),
        .vs_out     (vs_out),
        .de_out     (de_out),
        .x_out      (x_out),
        .y_out      (y_out)
    );

    always #20 clk = ~clk;   // 25MHz

    integer errors = 0;
    integer checks = 0;

    //-------------------------------------------------------------------------
    // 参考模型：out = clamp((c-128)*ct/128 + 128 + br, 0, 255)
    //-------------------------------------------------------------------------
    function [7:0] ref_ch;
        input [7:0]        c;
        input [7:0]        k;
        input signed [7:0] b;
        integer p, g, t;
        begin
            p = (c - 128) * k;
            g = p >>> 7;            // 与 RTL 一致：算术右移（向负无穷取整）
            t = g + 128 + b;
            if (t < 0)        ref_ch = 8'd0;
            else if (t > 255) ref_ch = 8'd255;
            else              ref_ch = t[7:0];
        end
    endfunction

    function [23:0] ref_rgb;
        input [23:0]       d;
        input [7:0]        k;
        input signed [7:0] b;
        begin
            ref_rgb = { ref_ch(d[23:16], k, b),
                        ref_ch(d[15:8],  k, b),
                        ref_ch(d[7:0],   k, b) };
        end
    endfunction

    // vs 负极性下降沿：参数锁存只在 vs_fall 生效
    task pulse_vs;
        begin
            @(negedge clk);
            vs_in = 1'b0;
            @(negedge clk);
            vs_in = 1'b1;
            @(negedge clk);
        end
    endtask

    // 单个像素检查：调好参数后送 1 个像素，6 拍后比对
    task chk_pixel;
        input [23:0]       din;
        input [9:0]        px;
        input [9:0]        py;
        input signed [7:0] b;
        input [7:0]        k;
        begin
            br = b;
            ct = k;
            repeat (16) @(posedge clk);   // 2FF + 稳定计数（8 拍）+ 余量
            pulse_vs;                     // vs 边界整组锁存
            repeat (4) @(posedge clk);    // 锁存后到流水输出
            @(negedge clk);
            rgb_in = din;
            x_in   = px;
            y_in   = py;
            de_in  = 1'b1;
            repeat (6) @(posedge clk);    // fx(3) + proc(2) + viz(1) = 6 拍
            #1;
            checks = checks + 1;
            if (rgb_out !== ref_rgb(din, k, b)) begin
                errors = errors + 1;
                $display("FAIL rgb: in=%h br=%0d ct=%0d out=%h exp=%h",
                         din, b, k, rgb_out, ref_rgb(din, k, b));
            end
            if (x_out !== px || y_out !== py || de_out !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL sideband: x=%0d/%0d y=%0d/%0d de=%b",
                         x_out, px, y_out, py, de_out);
            end
            @(negedge clk);
            de_in = 1'b0;
        end
    endtask

    //-------------------------------------------------------------------------
    // 延迟检查：连续送 8 个像素，验证 rgb/hs/vs/de/x/y 都延迟 6 拍
    //-------------------------------------------------------------------------
    reg [23:0] h_rgb [0:7];
    reg [9:0]  h_x   [0:7];
    reg [9:0]  h_y   [0:7];
    reg        h_hs  [0:7];
    reg        h_vs  [0:7];
    reg        h_de  [0:7];

    integer i;
    integer n;

    initial begin
        for (i = 0; i < 8; i = i + 1) begin
            h_rgb[i] = 24'd0;
            h_x[i]   = 10'd0;
            h_y[i]   = 10'd0;
            h_hs[i]  = 1'b1;
            h_vs[i]  = 1'b1;
            h_de[i]  = 1'b0;
        end

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        //--- 1) 恒等 + 延迟 ------------------------------------------------
        br = 8'sd0;
        ct = 8'd128;
        osd_en = 1'b0;
        repeat (16) @(posedge clk);   // 参数稳定
        pulse_vs;                     // 锁存 osd_en=0（关闭 OSD/Logo）
        repeat (4) @(posedge clk);

        for (n = 0; n < 8; n = n + 1) begin
            @(negedge clk);
            // 覆盖 0/1/127/128/129/254/255 等边界
            case (n)
                0: rgb_in = 24'h000000;
                1: rgb_in = 24'h010101;
                2: rgb_in = 24'h7F7F7F;
                3: rgb_in = 24'h808080;
                4: rgb_in = 24'h818181;
                5: rgb_in = 24'hFEFEFE;
                6: rgb_in = 24'hFFFFFF;
                default: rgb_in = 24'h123456;
            endcase
            x_in  = 10'd100 + n;
            y_in  = 10'd200 + n;
            de_in = (n % 2) ? 1'b0 : 1'b1;
            hs_in = n[0];
            vs_in = n[1];
            @(posedge clk);
            #1;

            // 影子寄存器：[5] = 6 拍前的输入
            checks = checks + 1;
            if (rgb_out !== h_rgb[5]) begin
                errors = errors + 1;
                $display("FAIL identity rgb @%0d: out=%h exp=%h", n, rgb_out, h_rgb[5]);
            end
            if (x_out !== h_x[5] || y_out !== h_y[5] ||
                de_out !== h_de[5] || hs_out !== h_hs[5] || vs_out !== h_vs[5]) begin
                errors = errors + 1;
                $display("FAIL identity sideband @%0d: x=%0d/%0d y=%0d/%0d de=%b/%b hs=%b/%b vs=%b/%b",
                         n, x_out, h_x[5], y_out, h_y[5],
                         de_out, h_de[5], hs_out, h_hs[5], vs_out, h_vs[5]);
            end
        end

        repeat (4) @(posedge clk);

        //--- 2) 亮度 -------------------------------------------------------
        chk_pixel(24'h808080, 10'd10, 10'd20,  8'sd8,  8'd128);  // 128+8=136
        chk_pixel(24'h808080, 10'd11, 10'd20, -8'sd8,  8'd128);  // 128-8=120
        chk_pixel(24'hFFFFFF, 10'd12, 10'd20,  8'sd64, 8'd128);  // clamp 255
        chk_pixel(24'h000000, 10'd13, 10'd20,  8'sd64, 8'd128);  // 64
        chk_pixel(24'h000000, 10'd14, 10'd20, -8'sd64, 8'd128);  // clamp 0

        //--- 3) 对比度 -----------------------------------------------------
        chk_pixel(24'h404040, 10'd15, 10'd20, 8'sd0, 8'd192);    // 32
        chk_pixel(24'hC0C0C0, 10'd16, 10'd20, 8'sd0, 8'd192);    // 224
        chk_pixel(24'h404040, 10'd17, 10'd20, 8'sd0, 8'd64);     // 96
        chk_pixel(24'h000000, 10'd18, 10'd20, 8'sd0, 8'd64);     // 64
        chk_pixel(24'hFFFFFF, 10'd19, 10'd20, 8'sd0, 8'd192);    // clamp 255

        //--- 4) 亮度 + 对比度组合 -----------------------------------------
        chk_pixel(24'h404040, 10'd20, 10'd20, 8'sd16, 8'd192);   // 32+16=48
        chk_pixel(24'hC0C0C0, 10'd21, 10'd20, -8'sd16, 8'd192);  // 224-16=208

        $display("--------------------------------------------------");
        $display("tb_video_post: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("tb_video_post: PASS");
        else
            $display("tb_video_post: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

    //-------------------------------------------------------------------------
    // 影子寄存器更新（与 DUT 输入同拍）
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        for (i = 0; i < 7; i = i + 1) begin
            h_rgb[i+1] <= h_rgb[i];
            h_x[i+1]   <= h_x[i];
            h_y[i+1]   <= h_y[i];
            h_hs[i+1]  <= h_hs[i];
            h_vs[i+1]  <= h_vs[i];
            h_de[i+1]  <= h_de[i];
        end
        h_rgb[0] <= rgb_in;
        h_x[0]   <= x_in;
        h_y[0]   <= y_in;
        h_hs[0]  <= hs_in;
        h_vs[0]  <= vs_in;
        h_de[0]  <= de_in;
    end

endmodule

