`timescale 1ns / 1ps
//=============================================================================
// video_fx.v — 实时风格化滤镜（锐化 / 线稿 / 浮雕 / 卡通 / 灰度 / 反色 / 暖调）
//-----------------------------------------------------------------------------
// 定位：
//   串在 video_proc（亮度/对比度）**之前**、mixer 之后的一级纯像素域后处理。
//   「官方扩展需求」里只有亮度/对比度，没有风格化滤镜，本模块是自选加分项：
//   同一个键循环切换 8 种画面风格，纯硬件实时处理（无处理器、无帧缓存）。
//
// 邻域怎么来（关键：只增加 6 个 BRAM9K，不碰 SDRAM）：
//   本模块内部自带 **1 条行延迟 RAM**（EG_LOGIC_BRAM，PDPW 模式），
//   采用「行号奇偶分 bank」技巧，**同一个 BRAM 同时承担读写**：
//       地址 = { bank, x[9:0] }，bank = y[0]
//       写：bank = y[0]   ← 当前正在进来的这一行
//       读：bank = ~y[0]  ← 上一行（同 x），读延迟固定 1 拍
//   因为读地址和写地址的 bank 位相反，读写永远不会撞同一地址，
//   不需要双口 RAM、不需要第二条行缓冲，也不需要任何 SDRAM 带宽。
//   于是拿到的窗口是 **2 行 × 3 列**（上左/上中/左/中/右），
//   足够做横向+纵向的锐化、梯度线稿、对角浮雕、卡通描边。
//
// 窗口对齐（严格同拍，这是本模块最需要小心的地方）：
//   记 C(k) = 当前行第 k 列的输入像素，P(k) = 上一行第 k 列的像素，
//   t 为周期序号（x_in 在 de 有效期内随 t 递增，x_in(t) = t）：
//       c0(t) = C(t-1)   c1(t) = C(t-2)   c2(t) = C(t-3)
//       p1(t) = P(t-2)   p2(t) = P(t-3)      （BRAM 1 拍 + 1 拍寄存器）
//   第 t 拍可组合出「中心 = (列 t-2, 行 y)」的完整 5 邻域：
//       中心 c1 = C(t-2)   左 c2 = C(t-3)   右 c0 = C(t-1)
//       上   p1 = P(t-2)   左上 p2 = P(t-3)
//   末级再把结果打 1 拍 → O_rgb(t) = f(C(t-3))，即在列 t-3 处成立；
//   而 de/x/y 同样延迟 3 拍 → x_out(t) = x_in(t-3) = t-3。
//   **对齐结论：本模块延迟恒定 3 拍，I_mode=0 时逐像素直通（与合入前完全一致）。**
//   注意：不要把它改成「延迟 2 拍 + 组合输出」，否则 x/y 与中心像素会差 1 列。
//
// 模式表（I_mode[2:0]，键 K14 循环）：
//   0 OFF     直通（逐像素 bit-exact，最有力的自检手段）
//   1 SHARPEN 锐化：  out = clamp(2C - (L+R+U+UL)/4)            增益 1.0
//   2 SKETCH  线稿：  梯度 g = |L-R| + |U-C|（亮度域），out = 255 - min(255, 2g)
//   3 EMBOSS  浮雕：  out = clamp(C - UL + 128)                  对角浮雕
//   4 CARTOON 卡通：  梯度 > 96 画黑边，否则每通道量化到 4 级（0/85/170/255）
//   5 GRAY    灰度：  out = (R + 2G + B) / 4
//   6 INVERT  反色：  out = ~C
//   7 WARM    暖调：  R'=R+R/4+8, G'=G+G/8, B'=B-B/8
//
// 资源（估算）：
//   BRAM9K  +6（1 条 2048×24 行延迟 RAM，2048×4 配置 ×6 块）
//   DSP      0（全部为加减法 + 常数移位，无乘法器）
//   LUT     ~350（7 种模式并行算出来再 8 选 1，模式是寄存器所以不会被综合剪掉）
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效（与 video_proc 一致）。
//
// 接口：
//   in  I_mode[2:0]  风格（必须在 vs 帧边界整组锁存后送进来，避免半帧切换）
//   in  I_de/I_x/I_y/I_rgb   像素流水（与 mixer 输出严格同拍）
//   out O_de/O_x/O_y/O_rgb   延迟 3 拍后的像素流水（仍严格同拍）
//
// 设计禁忌（踩过的坑，勿改）：
//   1) 不用数组 + for 循环做延迟线/邻域——TD 会把数组和循环折叠掉
//      （spectrum_analyzer 被优化掉的教训），这里全部用显式寄存器。
//   2) 不用推断 RAM——统一用 EG_LOGIC_BRAM（PDPW），与 line_buffer.v 一致。
//   3) de=0（消隐期）不写 RAM，输出由 de 延迟 3 拍把关，消隐区严格直通。
//=============================================================================
module video_fx (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire [2:0]  I_mode,

    input  wire        I_de,
    input  wire [9:0]  I_x,
    input  wire [9:0]  I_y,
    input  wire [23:0] I_rgb,

    output wire        O_de,
    output wire [9:0]  O_x,
    output wire [9:0]  O_y,
    output wire [23:0] O_rgb
);

    //-------------------------------------------------------------------------
    // 模式编码
    //-------------------------------------------------------------------------
    localparam [2:0] M_OFF     = 3'd0;
    localparam [2:0] M_SHARPEN = 3'd1;
    localparam [2:0] M_SKETCH  = 3'd2;
    localparam [2:0] M_EMBOSS  = 3'd3;
    localparam [2:0] M_CARTOON = 3'd4;
    localparam [2:0] M_GRAY    = 3'd5;
    localparam [2:0] M_INVERT  = 3'd6;
    localparam [2:0] M_WARM    = 3'd7;

    localparam [7:0] CARTOON_TH = 8'd96;    // 卡通描边阈值（亮度梯度，0..255）

    //-------------------------------------------------------------------------
    // ① 行延迟 RAM：一个 BRAM 正反 bank 同时读写
    //    地址 = {bank, x[9:0]}（11 位，深度 2048；x 在消隐期最大 799 也不越界）
    //-------------------------------------------------------------------------
    wire [10:0] ram_waddr = { I_y[0], I_x };    // 写：当前行
    wire [10:0] ram_raddr = {~I_y[0], I_x };    // 读：上一行（同列）

    wire [23:0] ram_dout;

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A  (24),
        .DATA_WIDTH_B  (24),
        .ADDR_WIDTH_A  (11),
        .ADDR_WIDTH_B  (11),
        .DATA_DEPTH_A  (2048),
        .DATA_DEPTH_B  (2048),
        .MODE          ("PDPW"),
        .REGMODE_A     ("NOREG"),
        .REGMODE_B     ("NOREG"),
        .WRITEMODE_A   ("NORMAL"),
        .WRITEMODE_B   ("NORMAL"),
        .RESETMODE     ("SYNC"),
        .IMPLEMENT     ("9K"),
        .INIT_FILE     ("NONE"),
        .FILL_ALL      ("NONE")
    ) u_line (
        .dia   (I_rgb),
        .dib   (24'd0),
        .addra (ram_waddr),
        .addrb (ram_raddr),
        .cea   (I_de),          // de=0 不写，消隐区不污染行缓冲
        .ceb   (1'b1),
        .ocea  (1'b0),
        .oceb  (1'b0),
        .clka  (I_clk),
        .clkb  (I_clk),
        .wea   (1'b1),
        .web   (1'b0),
        .bea   (1'b0),
        .beb   (1'b0),
        .rsta  (1'b0),
        .rstb  (1'b0),
        .doa   (),
        .dob   (ram_dout)
    );

    //-------------------------------------------------------------------------
    // ② 像素延迟线（显式寄存器，禁止数组/循环）
    //    c0=C(t-1)  c1=C(t-2)  c2=C(t-3)   p1=P(t-2)  p2=P(t-3)
    //-------------------------------------------------------------------------
    reg [23:0] c0, c1, c2;
    reg [23:0] p1, p2;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            c0 <= 24'd0;
            c1 <= 24'd0;
            c2 <= 24'd0;
            p1 <= 24'd0;
            p2 <= 24'd0;
        end else begin
            c0 <= I_rgb;
            c1 <= c0;
            c2 <= c1;
            p1 <= ram_dout;         // BRAM 1 拍 + 本拍 = 列 t-2
            p2 <= p1;               // 列 t-3
        end
    end

    // 邻域名（中心 = (列 t-2, 行 y)）
    wire [23:0] s_c  = c1;      // 中心 C(t-2)
    wire [23:0] s_l  = c2;      // 左   C(t-3)
    wire [23:0] s_r  = c0;      // 右   C(t-1)
    wire [23:0] s_u  = p1;      // 上   P(t-2)
    wire [23:0] s_ul = p2;      // 左上 P(t-3)

    //-------------------------------------------------------------------------
    // ③ 亮度与梯度（10bit 求和，避免精度丢失）
    //-------------------------------------------------------------------------
    wire [9:0] lum_c = {2'b00, s_c[23:16]} + {1'b0, s_c[15:8], 1'b0} + {2'b00, s_c[7:0]};
    wire [9:0] lum_l = {2'b00, s_l[23:16]} + {1'b0, s_l[15:8], 1'b0} + {2'b00, s_l[7:0]};
    wire [9:0] lum_r = {2'b00, s_r[23:16]} + {1'b0, s_r[15:8], 1'b0} + {2'b00, s_r[7:0]};
    wire [9:0] lum_u = {2'b00, s_u[23:16]} + {1'b0, s_u[15:8], 1'b0} + {2'b00, s_u[7:0]};

    wire [9:0]  gdx    = (lum_r >= lum_l) ? (lum_r - lum_l) : (lum_l - lum_r);
    wire [9:0]  gdy    = (lum_u >= lum_c) ? (lum_u - lum_c) : (lum_c - lum_u);
    wire [10:0] grad11 = {1'b0, gdx} + {1'b0, gdy};
    wire [7:0]  grad8  = (grad11 > 11'd255) ? 8'd255 : grad11[7:0];

    wire [7:0] luma8 = lum_c[9:2];                  // (R+2G+B)/4

    //-------------------------------------------------------------------------
    // ④ 各模式的逐通道运算（函数在综合时全部内联，无运行时开销）
    //-------------------------------------------------------------------------
    // 锐化：out = clamp(2C - (L+R+U+UL)/4)
    function [7:0] fx_shp;
        input [7:0] c, l, r, u, ul;
        reg [9:0] s4;
        reg signed [11:0] v;
        begin
            s4 = {2'b00, l} + {2'b00, r} + {2'b00, u} + {2'b00, ul};
            v  = $signed({2'b00, c, 1'b0}) - $signed({2'b00, s4[9:2]});
            if (v < 12'sd0)
                fx_shp = 8'd0;
            else if (v > 12'sd255)
                fx_shp = 8'd255;
            else
                fx_shp = v[7:0];
        end
    endfunction

    // 浮雕：out = clamp(C - UL + 128)
    function [7:0] fx_emb;
        input [7:0] c, ul;
        reg signed [10:0] v;
        begin
            v = $signed({3'b000, c}) - $signed({3'b000, ul}) + 11'sd128;
            if (v < 11'sd0)
                fx_emb = 8'd0;
            else if (v > 11'sd255)
                fx_emb = 8'd255;
            else
                fx_emb = v[7:0];
        end
    endfunction

    // 卡通量化：取高 2 位 → 4 级 {0,85,170,255}（纯连线，0 LUT）
    function [7:0] fx_post;
        input [7:0] c;
        begin
            fx_post = {c[7], c[6], c[7], c[6], c[7], c[6], c[7], c[6]};
        end
    endfunction

    // 线稿：白底黑线，梯度越大越黑
    function [7:0] fx_sketch;
        input [7:0] g;
        reg [7:0] e;
        begin
            e         = g[7] ? 8'd255 : {g[6:0], 1'b0};
            fx_sketch = 8'd255 - e;
        end
    endfunction

    // 暖调三通道
    function [7:0] fx_warm_r;
        input [7:0] c;
        reg [8:0] t;
        begin
            t        = {1'b0, c} + {2'b00, c[7:2]} + 9'd8;
            fx_warm_r = t[8] ? 8'd255 : t[7:0];
        end
    endfunction

    function [7:0] fx_warm_g;
        input [7:0] c;
        reg [8:0] t;
        begin
            t        = {1'b0, c} + {3'b000, c[7:3]};
            fx_warm_g = t[8] ? 8'd255 : t[7:0];
        end
    endfunction

    function [7:0] fx_warm_b;
        input [7:0] c;
        begin
            fx_warm_b = c - {3'b000, c[7:3]};
        end
    endfunction

    wire       is_edge = (grad8 > CARTOON_TH);
    wire [7:0] sk8     = fx_sketch(grad8);

    //-------------------------------------------------------------------------
    // ⑤ 模式选择（8 选 1）
    //-------------------------------------------------------------------------
    reg [23:0] fx;

    always @(*) begin
        case (I_mode)
            M_SHARPEN: fx = { fx_shp(s_c[23:16], s_l[23:16], s_r[23:16], s_u[23:16], s_ul[23:16]),
                              fx_shp(s_c[15:8],  s_l[15:8],  s_r[15:8],  s_u[15:8],  s_ul[15:8]),
                              fx_shp(s_c[7:0],   s_l[7:0],   s_r[7:0],   s_u[7:0],   s_ul[7:0]) };
            M_SKETCH:  fx = { sk8, sk8, sk8 };
            M_EMBOSS:  fx = { fx_emb(s_c[23:16], s_ul[23:16]),
                              fx_emb(s_c[15:8],  s_ul[15:8]),
                              fx_emb(s_c[7:0],   s_ul[7:0]) };
            M_CARTOON: fx = is_edge ? 24'h000000
                                    : { fx_post(s_c[23:16]), fx_post(s_c[15:8]), fx_post(s_c[7:0]) };
            M_GRAY:    fx = { luma8, luma8, luma8 };
            M_INVERT:  fx = ~s_c;
            M_WARM:    fx = { fx_warm_r(s_c[23:16]), fx_warm_g(s_c[15:8]), fx_warm_b(s_c[7:0]) };
            default:   fx = s_c;        // M_OFF 以及未定义编码 → 直通
        endcase
    end

    //-------------------------------------------------------------------------
    // ⑥ 输出寄存器 + de/x/y 同步延迟 3 拍
    //-------------------------------------------------------------------------
    reg        de1, de2, de3;
    reg [9:0]  x1,  x2,  x3;
    reg [9:0]  y1,  y2,  y3;
    reg [23:0] rgb_r;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            de1   <= 1'b0;
            de2   <= 1'b0;
            de3   <= 1'b0;
            x1    <= 10'd0;
            x2    <= 10'd0;
            x3    <= 10'd0;
            y1    <= 10'd0;
            y2    <= 10'd0;
            y3    <= 10'd0;
            rgb_r <= 24'd0;
        end else begin
            de1   <= I_de;
            de2   <= de1;
            de3   <= de2;
            x1    <= I_x;
            x2    <= x1;
            x3    <= x2;
            y1    <= I_y;
            y2    <= y1;
            y3    <= y2;
            rgb_r <= fx;
        end
    end

    assign O_de  = de3;
    assign O_x   = x3;
    assign O_y   = y3;
    assign O_rgb = rgb_r;

endmodule
