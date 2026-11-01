//=============================================================================
// scroll_text_overlay.v — 底部中文滚动字幕图层（M2 扩展⑤）
//-----------------------------------------------------------------------------
// 功能：
//   在画面底部叠加 16x16 中文点阵（红色字，**背景透明**），从右向左循环滚动。
//   本工程内置文本：「逐逻辑而行，赴创新之约」（11 个全角字符，见
//   font_cn_16x16.v 的码表；改文本需重新运行生成器并同步 TEXT_N）。
//
// 叠加方式（逐像素二选一，零乘法、零 BRAM、零延迟）：
//   字形像素：红色 24'hFF0000（R=255,G=0,B=0）
//   其余像素（字形外 / de=0 / I_en=0）：原像素逐位直通 → **背景完全透明**，
//   对背景图、A/B 转场、OSD 全部无影响
//   （字色由下方 TEXT_RGB 决定，改一行即可换色）
//
// 滚动规则：
//   pos 表示「文本第 0 个像素」的屏幕 X 坐标（可以为负）。
//   上电 pos = 640（完全在右侧屏幕外），每个 vs 帧边界减小 1（FRAME_DIV=1
//   时约 59.5 px/s）；pos 滚到 -(TEXT_W+GAP) 后回到 640，形成无缝循环。
//   位置只在帧边界更新 → 帧内坐标恒定，绝不会出现同一帧上下错位（撕裂）。
//   关闭字幕时滚动位置冻结（暂停），重新打开从暂停处继续。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效；I_vs 负极性（低有效）。
//   像素通路为纯组合（与 I_rgb 同拍），仅 pos 在时钟域内更新。
//
// 接口：
//   in  I_clk / I_rst / I_vs       video_clk 域，vs 用于帧边界
//   in  I_de / I_x / I_y / I_rgb   来自上一层（必须与 I_rgb 同拍）
//   in  I_en                       字幕总开关（0 = 完全直通且暂停滚动）
//   out O_de / O_x / O_y / O_rgb   叠加后的像素（坐标/使能原样直通）
//
// 参数/常量：
//   TEXT_N    = 11    字符个数（必须与 font_cn_16x16.v 一致）
//   GLYPH_W   = 16    每个字符宽（汉字全角）
//   Y0        = 448   文本顶部 Y（480 - 16 - 16，底部留 16px 边距）
//   BAND_Y0   = 444   字幕带顶部 Y（文本上下各留 4px）
//   BAND_H    = 24    字幕带高度
//   GAP       = 64    循环时两轮文本之间的空白像素
//   FRAME_DIV = 1     每 N 帧滚动 1 像素（1≈59.5px/s，调大即变慢）
//   BAND_RGB / TEXT_RGB  底条与字形的颜色（默认白底红字）
//
// 内部例化：
//   font_cn_16x16   16x16 中文点阵，组合 LUT ROM（0 BRAM，0 拍延迟）
//
// 备注：
//   1) 本模块不引入任何流水延迟：O_de/O_x/O_y 与 I_* 同拍，O_rgb 也是同拍，
//      所以插到 video_post 里既不影响 hs/vs 的既有 2 拍对齐，也不会改变
//      帧缓存/行缓冲/转场的行为 —— 只改「最终送出去的像素值」。
//      若将来把字库换成同步读 BRAM，必须同时把 I_rgb/I_de/I_x/I_y 打一拍。
//   2) de=0（消隐区）/ 字幕带外 / I_en=0 全部逐像素直通，绝不污染 HDMI 消隐。
//   3) 想挪位置或改字号：改 Y0/BAND_Y0 与字库即可，滚动逻辑与分辨率无关。
//=============================================================================
`timescale 1ns / 1ps

module scroll_text_overlay #(
    parameter integer TEXT_N    = 11,   // 与 font_cn_16x16.v 的字符数一致
    parameter integer FRAME_DIV = 1,    // 每 N 帧滚动 1 像素（越大越慢）
    parameter integer GAP       = 64    // 循环间隙（像素）
)(
    input  wire              I_clk,
    input  wire              I_rst,
    input  wire              I_vs,

    input  wire              I_de,
    input  wire [9:0]        I_x,
    input  wire [9:0]        I_y,
    input  wire [23:0]       I_rgb,
    input  wire              I_en,

    output wire              O_de,
    output wire [9:0]        O_x,
    output wire [9:0]        O_y,
    output wire [23:0]       O_rgb
);

    //-------------------------------------------------------------------------
    // 布局常量
    //-------------------------------------------------------------------------
    localparam integer GLYPH_W = 16;
    localparam integer TEXT_W  = TEXT_N * GLYPH_W;   // 11*16 = 176

    localparam [9:0] Y0      = 10'd448;   // 文本顶部

    // pos 的循环区间：640（完全在右侧） → -(TEXT_W+GAP)（完全滚出左侧）
    localparam signed [11:0] POS_START = 12'sd640;
    localparam signed [11:0] POS_MIN   = -(TEXT_W + GAP);
    localparam integer       FD        = (FRAME_DIV < 1) ? 1 : FRAME_DIV;

    //-------------------------------------------------------------------------
    // 滚动位置（只在 vs 帧边界更新，帧内恒定 → 无撕裂）
    //-------------------------------------------------------------------------
    reg  signed [11:0] pos;
    reg  [7:0]         frame_div;
    reg                vs_d;

    wire vs_fall = vs_d & ~I_vs;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            vs_d <= 1'b0;
        else
            vs_d <= I_vs;
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            pos       <= POS_START;
            frame_div <= 8'd0;
        end else if (vs_fall && I_en) begin
            if ((frame_div + 8'd1) >= FD) begin
                frame_div <= 8'd0;
                if (pos <= POS_MIN)
                    pos <= POS_START;
                else
                    pos <= pos - 12'sd1;
            end else begin
                frame_div <= frame_div + 8'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 坐标 → 文本内位置
    //-------------------------------------------------------------------------
    wire signed [11:0] dx = $signed({2'b00, I_x}) - pos;

    wire in_strip = (dx >= 12'sd0) && (dx < TEXT_W);

    wire [7:0]  dx_u  = dx[7:0];              // 0..175（< 256）
    wire [3:0]  ch    = dx_u[7:4];            // 第几个字符
    wire [3:0]  col   = dx_u[3:0];            // 字符内列 0..15

    wire in_text_row = (I_y >= Y0) && (I_y < (Y0 + 10'd16));
    wire [3:0] row   = (I_y - Y0);

    //-------------------------------------------------------------------------
    // 字库查表（组合）
    //-------------------------------------------------------------------------
    wire [15:0] glyph;
    wire        pix_on = glyph[4'd15 - col];   // bit15 = 最左像素

    font_cn_16x16 u_font (
        .I_code (ch),
        .I_row  (row),
        .O_bits (glyph)
    );

    //-------------------------------------------------------------------------
    // 像素叠加（字幕带**透明**：只有字形像素着色，其余像素原样透出下层视频）
    //-------------------------------------------------------------------------
    localparam [23:0] TEXT_RGB = 24'hFF0000;   // 字形：红色 R=255,G=0,B=0

    wire hit_text = I_en && I_de && in_text_row && in_strip && pix_on;

    assign O_de  = I_de;
    assign O_x   = I_x;
    assign O_y   = I_y;
    assign O_rgb = hit_text ? TEXT_RGB : I_rgb;

endmodule
