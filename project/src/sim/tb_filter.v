`timescale 1ns / 1ps
//=============================================================================
// tb_filter.v — video_fx 自检（iverilog / ModelSim 通用）
//-----------------------------------------------------------------------------
// 验证内容：
//   1) 延迟恒定 3 拍，且 de/x/y 与像素严格同拍（被动监视：de 有效的每个输出
//     像素都按 O_x/O_y 记录，行内 x 必须是 0,1,2,...,15 连续递增）；
//   2) I_mode=0 逐像素 bit-exact 直通（与合入本模块之前的画面完全一致）；
//   3) 8 种模式的逐通道结果与软件参考模型完全一致
//      （锐化/线稿/浮雕/卡通/灰度/反色/暖调，含 0/255 两端饱和不环绕）；
//   4) 邻域取自「上一行 + 同一行左右各 1 列」（行延迟 RAM + 行内延迟线）。
//
// 做法：喂一张 4 行 × 16 列的合成小图（平坦区 / 纵向阶跃 / 横向渐变 /
//       黑白交替），被动监视 DUT 输出；每个输出像素都用 tb 内的参考模型
//       重算一遍并比对。参考模型只检查 x>=2 且 y>=1 的像素（左上角那几个
//       像素的邻域落在图像外，属于无定义区，与 RTL 一致地跳过）。
//
// 用法：
//   iverilog : 由 run_sim.ps1 统一调用（需要 base_stubs.v 提供 EG_LOGIC_BRAM）
//   ModelSim :  vlog +define+SIM_STUBS base_stubs.v video_fx.v tb_filter.v
//               vsim -c tb_filter -do "run -all; quit"
//=============================================================================

module tb_filter;

    localparam integer COLS = 16;
    localparam integer ROWS = 4;

    reg               clk = 1'b0;
    reg               rst = 1'b1;
    reg  [2:0]        mode = 3'd0;
    reg               de_in = 1'b0;
    reg  [9:0]        x_in = 10'd0;
    reg  [9:0]        y_in = 10'd0;
    reg  [23:0]       rgb_in = 24'd0;

    wire              o_de;
    wire [9:0]        o_x, o_y;
    wire [23:0]       o_rgb;

    video_fx dut (
        .I_clk  (clk),
        .I_rst  (rst),
        .I_mode (mode),
        .I_de   (de_in),
        .I_x    (x_in),
        .I_y    (y_in),
        .I_rgb  (rgb_in),
        .O_de   (o_de),
        .O_x    (o_x),
        .O_y    (o_y),
        .O_rgb  (o_rgb)
    );

    always #20 clk = ~clk;      // 25MHz 像素时钟

    //-------------------------------------------------------------------------
    // 测试图像（灰度，三通道相同；0..255）
    //   row0 全 0x40            → 平坦暗区
    //   row1 左 0x40 / 右 0xC0  → 纵向阶跃（测锐化过冲、线稿描边、卡通描边）
    //   row2 横向渐变 x*16      → 测量化/浮雕
    //   row3 黑白交替           → 测 0/255 两端饱和
    //-------------------------------------------------------------------------
    integer img [0:ROWS-1][0:COLS-1];

    // 函数/任务内部临时变量（提到模块作用域，保证 Verilog-2001 兼容）
    integer iy, ix;          // fill_img 循环
    integer bk;              // feed_blank 循环
    integer tmp_s4, tmp_e, tmp_gx, tmp_gy;

    task fill_img;
        begin
            for (ix = 0; ix < COLS; ix = ix + 1) begin
                img[0][ix] = 8'h40;
                img[1][ix] = (ix < 8) ? 8'h40 : 8'hC0;
                img[2][ix] = ix * 16;
                img[3][ix] = ix[0] ? 8'h00 : 8'hFF;
            end
        end
    endtask

    function [23:0] px;
        input integer yy, xx;
        begin
            px = {img[yy][xx][7:0], img[yy][xx][7:0], img[yy][xx][7:0]};
        end
    endfunction

    //-------------------------------------------------------------------------
    // 参考模型（必须与 video_fx.v 的算术逐位一致）
    //-------------------------------------------------------------------------
    function integer clamp255;
        input integer v;
        begin
            if (v < 0)          clamp255 = 0;
            else if (v > 255)   clamp255 = 255;
            else                clamp255 = v;
        end
    endfunction

    // 锐化：clamp(2C - (L+R+U+UL)/4)   （>>>2 = 向下取整，与 RTL 的 s4[9:2] 一致）
    function integer m_shp;
        input integer c, l, r, u, ul;
        begin
            tmp_s4 = l + r + u + ul;
            m_shp  = clamp255(2 * c - (tmp_s4 >>> 2));
        end
    endfunction

    // 浮雕：clamp(C - UL + 128)
    function integer m_emb;
        input integer c, ul;
        begin
            m_emb = clamp255(c - ul + 128);
        end
    endfunction

    // 卡通量化：高 2 位 → 0/85/170/255
    function integer m_post;
        input integer c;
        begin
            m_post = (c >> 6) * 85;
        end
    endfunction

    // 线稿：白底黑线（梯度越大越黑）
    function integer m_sketch;
        input integer g8;
        begin
            tmp_e    = (g8 >= 128) ? 255 : (2 * g8);
            m_sketch = 255 - tmp_e;
        end
    endfunction

    // 亮度梯度：g = |L-R| + |U-C|（亮度域，亮度 = R+2G+B = 4v），饱和到 255
    function integer m_grad;
        input integer c, l, r, u;
        begin
            tmp_gx = (r >= l) ? (4 * r - 4 * l) : (4 * l - 4 * r);
            tmp_gy = (u >= c) ? (4 * u - 4 * c) : (4 * c - 4 * u);
            m_grad = (tmp_gx + tmp_gy > 255) ? 255 : (tmp_gx + tmp_gy);
        end
    endfunction

    //-------------------------------------------------------------------------
    // 被动监视 + 逐像素比对
    //-------------------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;
    reg [9:0] exp_x = 10'd0;

    integer cy, cx, cc, cl, cr, cu, cul;
    integer eg, esh, eem, ewr, ewg, ewb, esk, epo;
    reg [23:0] exp_rgb;

    task check_out;
        input [9:0]    ox;
        input [9:0]    oy;
        input [23:0]   got;
        begin
            cy  = oy;
            cx  = ox;
            cc  = img[cy][cx];
            cl  = img[cy][cx-1];
            cr  = img[cy][cx+1];
            cu  = img[cy-1][cx];
            cul = img[cy-1][cx-1];

            eg  = m_grad(cc, cl, cr, cu);
            esh = m_shp(cc, cl, cr, cu, cul);
            eem = m_emb(cc, cul);
            ewr = clamp255(cc + (cc >> 2) + 8);
            ewg = clamp255(cc + (cc >> 3));
            ewb = clamp255(cc - (cc >> 3));
            esk = m_sketch(eg);
            epo = m_post(cc);

            case (mode)
                3'd0: exp_rgb = {cc[7:0], cc[7:0], cc[7:0]};
                3'd1: exp_rgb = {esh[7:0], esh[7:0], esh[7:0]};
                3'd2: exp_rgb = {esk[7:0], esk[7:0], esk[7:0]};
                3'd3: exp_rgb = {eem[7:0], eem[7:0], eem[7:0]};
                3'd4: exp_rgb = (eg > 96) ? 24'h000000
                                          : {epo[7:0], epo[7:0], epo[7:0]};
                3'd5: exp_rgb = {cc[7:0], cc[7:0], cc[7:0]};
                3'd6: exp_rgb = {~cc[7:0], ~cc[7:0], ~cc[7:0]};
                3'd7: exp_rgb = {ewr[7:0], ewg[7:0], ewb[7:0]};
                default: exp_rgb = 24'hxxxxxx;
            endcase

            checks = checks + 1;
            if (got !== exp_rgb) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL mode=%0d (%0d,%0d) c=%0d l=%0d r=%0d u=%0d ul=%0d got=%06h exp=%06h",
                             mode, cx, cy, cc, cl, cr, cu, cul, got, exp_rgb);
            end
        end
    endtask

    always @(posedge clk) begin
        if (o_de) begin
            // 行内 x 必须连续递增（验证 de/x/y 与像素同拍，没有错位）
            checks = checks + 1;
            if (o_x !== exp_x) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("FAIL sideband: o_x=%0d exp=%0d o_y=%0d", o_x, exp_x, o_y);
            end
            exp_x = (o_x == (COLS - 1)) ? 10'd0 : (o_x + 10'd1);

            // 邻域完整的像素才比对（x>=2 且 y>=1）
            if ((o_x >= 10'd2) && (o_x <= (COLS - 2)) && (o_y >= 10'd1) && (o_y < ROWS))
                check_out(o_x, o_y, o_rgb);
        end
    end

    //-------------------------------------------------------------------------
    // 激励
    //-------------------------------------------------------------------------
    integer m, yy, xx;

    task feed_blank;
        input integer n;
        begin
            @(negedge clk);
            de_in = 1'b0;
            for (bk = 0; bk < n; bk = bk + 1) @(posedge clk);
        end
    endtask

    initial begin
        fill_img;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (m = 0; m < 8; m = m + 1) begin
            mode = m[2:0];

            feed_blank(6);
            exp_x = 10'd0;

            for (yy = 0; yy < ROWS; yy = yy + 1) begin
                for (xx = 0; xx < COLS; xx = xx + 1) begin
                    @(negedge clk);
                    de_in  = 1'b1;
                    x_in   = xx[9:0];
                    y_in   = yy[9:0];
                    rgb_in = px(yy, xx);
                end
                feed_blank(6);      // 行尾消隐（不写行缓冲）
            end

            feed_blank(10);         // 帧尾，等流水排空
        end

        $display("--------------------------------------------------");
        $display("tb_filter: %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("tb_filter: PASS");
        else
            $display("tb_filter: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
