//=============================================================================
// tb_video_proc.v — video_proc 自检（ModelSim）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) 公式正确：逐通道 out = clamp((c-128)*contrast/128 + 128 + brightness, 0, 255)
//   2) 饱和边界：亮度 ±64、对比度 64/192 时不会环绕（0xFF→0x00 这类反相）
//   3) 延迟恒定：rgb / de / x / y 一致延迟 2 拍（坐标与像素仍然同拍）
//
// 用法（ModelSim）：
//   vlog font_ascii_8x16.v video_proc.v tb_video_proc.v
//   vsim -c tb_video_proc -do "run -all; quit"
//=============================================================================
`timescale 1ns / 1ps

module tb_video_proc;

    reg               clk = 1'b0;
    reg               rst = 1'b1;
    reg               de  = 1'b0;
    reg  [9:0]        x   = 10'd0;
    reg  [9:0]        y   = 10'd0;
    reg  [23:0]       rgb = 24'd0;
    reg  signed [7:0] br  = 8'sd0;
    reg  [7:0]        cnt = 8'd128;

    wire              o_de;
    wire [9:0]        o_x, o_y;
    wire [23:0]       o_rgb;

    video_proc dut (
        .I_clk        (clk),
        .I_rst        (rst),
        .I_de         (de),
        .I_x          (x),
        .I_y          (y),
        .I_rgb        (rgb),
        .I_brightness (br),
        .I_contrast   (cnt),
        .O_de         (o_de),
        .O_x          (o_x),
        .O_y          (o_y),
        .O_rgb        (o_rgb)
    );

    // 25MHz 像素时钟
    always #20 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    //-------------------------------------------------------------------------
    // 参考模型（必须与 RTL 完全一致：算术右移 = 向下取整）
    //-------------------------------------------------------------------------
    function [7:0] ref_ch;
        input [7:0]        c;
        input [7:0]        k;
        input signed [7:0] b;
        integer p, g, t;
        begin
            p = (c - 128) * k;      // integer 为 signed
            g = p >>> 7;            // 算术右移
            t = g + 128 + b;
            if (t < 0)
                ref_ch = 8'd0;
            else if (t > 255)
                ref_ch = 8'd255;
            else
                ref_ch = t[7:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 单个用例：驱动一拍，等 2 拍后比较
    //-------------------------------------------------------------------------
    task one_case;
        input [7:0]        c;
        input signed [7:0] b;
        input [7:0]        k;
        reg   [7:0]        er, eg, eb;
        begin
            @(negedge clk);
            de  = 1'b1;
            x   = 10'd123;
            y   = 10'd45;
            rgb = {c, c, c};
            br  = b;
            cnt = k;

            repeat (2) @(posedge clk);
            #1;

            er = ref_ch(c, k, b);
            eg = ref_ch(c, k, b);
            eb = ref_ch(c, k, b);

            checks = checks + 1;
            if (o_rgb !== {er, eg, eb}) begin
                errors = errors + 1;
                $display("FAIL rgb: c=%0d k=%0d b=%0d -> got %02x%02x%02x exp %02x%02x%02x",
                         c, k, b, o_rgb[23:16], o_rgb[15:8], o_rgb[7:0], er, eg, eb);
            end
            if (o_de !== 1'b1 || o_x !== 10'd123 || o_y !== 10'd45) begin
                errors = errors + 1;
                $display("FAIL align: c=%0d k=%0d b=%0d -> de=%b x=%0d y=%0d",
                         c, k, b, o_de, o_x, o_y);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer ci, bi, ki;
    reg [7:0] cs [0:8];
    reg signed [7:0] bs [0:2];
    reg [7:0] ks [0:2];
    integer i;

    initial begin
        cs[0] = 8'd0;   cs[1] = 8'd1;   cs[2] = 8'd64;
        cs[3] = 8'd127; cs[4] = 8'd128; cs[5] = 8'd129;
        cs[6] = 8'd192; cs[7] = 8'd254; cs[8] = 8'd255;

        bs[0] = -8'sd64; bs[1] = 8'sd0; bs[2] = 8'sd64;
        ks[0] = 8'd64;   ks[1] = 8'd128; ks[2] = 8'd192;

        // 复位
        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        //-------------------------------------------------------------------------
        // 1) 全组合遍历：9 灰阶 × 3 亮度 × 3 对比度
        //-------------------------------------------------------------------------
        for (ci = 0; ci < 9; ci = ci + 1)
            for (bi = 0; bi < 3; bi = bi + 1)
                for (ki = 0; ki < 3; ki = ki + 1)
                    one_case(cs[ci], bs[bi], ks[ki]);

        //-------------------------------------------------------------------------
        // 2) 彩色通道必须互不干扰
        //-------------------------------------------------------------------------
        @(negedge clk);
        de = 1'b1; x = 10'd1; y = 10'd2;
        rgb = 24'h40_80_C0; br = 8'sd8; cnt = 8'd160;
        repeat (2) @(posedge clk);
        #1;
        checks = checks + 1;
        if (o_rgb !== {ref_ch(8'h40, 8'd160, 8'sd8),
                       ref_ch(8'h80, 8'd160, 8'sd8),
                       ref_ch(8'hC0, 8'd160, 8'sd8)}) begin
            errors = errors + 1;
            $display("FAIL color isolation: got %06x", o_rgb);
        end

        //-------------------------------------------------------------------------
        // 3) de 也延迟 2 拍（消隐区不能提前拉高）
        //-------------------------------------------------------------------------
        @(negedge clk);
        de = 1'b0;
        @(posedge clk);
        #1;
        checks = checks + 1;
        if (o_de !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL de delay: still 1 at +1 cycle expected, got %b", o_de);
        end

        @(posedge clk);
        #1;
        checks = checks + 1;
        if (o_de !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL de delay: expected 0 at +2 cycles, got %b", o_de);
        end

        @(negedge clk);
        de = 1'b1;
        @(posedge clk);
        #1;
        checks = checks + 1;
        if (o_de !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL de pipeline: still 0 at +1 cycle after 0 (got %b)", o_de);
        end
        @(posedge clk);
        #1;
        checks = checks + 1;
        if (o_de !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL de pipeline: expected 1 at +2 cycle (got %b)", o_de);
        end

        $display("--------------------------------------------------");
        $display("tb_video_proc: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("tb_video_proc: PASS");
        else
            $display("tb_video_proc: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
