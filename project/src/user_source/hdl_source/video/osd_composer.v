//=============================================================================
// osd_composer.v — 右上角参数 OSD 叠加（扩展要求 ④「信息叠加」）
//-----------------------------------------------------------------------------
// 功能：
//   在画面上叠加一个 3 行 × 20 列、8×16 点阵的字符面板，实时回显：
//     第 1 行： TIME 00:00 IMG:1/4
//     第 2 行： BRT:+00 CNT:128 TR:0
//     第 3 行： MDE:1 TMB:1 SRC:0        （M3 扩展⑤：可视化开关/音色/音源）
//   其中 mm:ss 每秒跳变、IMG 随切图跳变、BRT/CNT/TR/MDE/TMB/SRC 随按键跳变。
//   MDE 只有 0/1 两态：1=波形+频谱同开，0=全关，与 OSD 面板共用 K4 开关。
//
// 叠加方式（零乘法、零 BRAM）：
//   字形像素 = 纯白 0xFFFFFF ；
//   非字形像素 = 原像素每通道右移 1 位（亮度减半），形成半透明黑底，
//   既保证文字可读，又不会完全遮住背景。
//
// 时钟/复位：纯组合逻辑（同拍直通）；I_rst 保留但当前未使用。
//
// 接口：
//   in  I_de / I_x / I_y / I_rgb   来自 video_proc 的像素（与 I_rgb 同拍）
//   in  I_en                       OSD 总开关
//   in  I_*_ch[4:0]                参数字符码（来自 video_param_latch，帧内恒定）
//   out O_de / O_x / O_y / O_rgb   叠加后的像素（坐标/使能原样直通）
//
// 参数/常量：
//   X0 = 472       面板左上角 X（640 - 160 - 8，右侧留 8px 边距）
//   Y0 = 8         面板左上角 Y（顶部留 8px 边距）
//   COLS = 20      每行字符数
//   CH_W = 8       字符宽
//   LINE_H = 18    行间距（16 行点阵 + 2 行空隙）
//
// 内部例化：
//   font_ascii_8x16   8×16 ASCII 精简字库（组合 LUT ROM）
//
// 备注：
//   1) 本模块不做行缓冲，只在 de=1 且坐标落在面板内时替换像素；
//      de=0（消隐区）严格直通，避免污染 HDMI 行场消隐。
//   2) I_en=0 时完全直通，输出与输入逐像素一致 —— 这是最好用的自检：
//      关掉 OSD 后画面应与合入本模块之前完全相同。
//   3) 字库是组合查表，与本模块同拍，因此 x/y 不需要额外延迟补偿。
//      如果将来把字库换成同步读 BRAM，必须把 I_rgb/I_x/I_y 一起打拍对齐。
//=============================================================================
`timescale 1ns / 1ps

module osd_composer(
    input  wire              I_de,
    input  wire [9:0]        I_x,
    input  wire [9:0]        I_y,
    input  wire [23:0]       I_rgb,
    input  wire              I_en,

    input  wire [4:0]        I_brt_sign,
    input  wire [4:0]        I_brt_hi,
    input  wire [4:0]        I_brt_lo,
    input  wire [4:0]        I_cnt_h,
    input  wire [4:0]        I_cnt_m,
    input  wire [4:0]        I_cnt_l,
    input  wire [4:0]        I_mm_hi,
    input  wire [4:0]        I_mm_lo,
    input  wire [4:0]        I_ss_hi,
    input  wire [4:0]        I_ss_lo,
    input  wire [4:0]        I_img,
    input  wire [4:0]        I_tr,
    input  wire [4:0]        I_viz_mode,
    input  wire [4:0]        I_timbre,
    input  wire [4:0]        I_audio_src,

    output wire              O_de,
    output wire [9:0]        O_x,
    output wire [9:0]        O_y,
    output wire [23:0]       O_rgb
);

    //-------------------------------------------------------------------------
    // 布局常量
    //-------------------------------------------------------------------------
    localparam [9:0] X0     = 10'd472;
    localparam [9:0] Y0     = 10'd8;
    localparam [9:0] PANEL_W = 10'd160;   // 20 × 8
    localparam [9:0] PANEL_H = 10'd52;    // 3 × 18 - 2（最后一行不留空地）

    // 字符码（与 font_ascii_8x16.v 码表一致）
    localparam [4:0] CH_SP    = 5'd14;
    localparam [4:0] CH_COLON = 5'd10;
    localparam [4:0] CH_SLASH = 5'd11;
    localparam [4:0] CH_4     = 5'd4;     // 数字 '4'
    localparam [4:0] CH_T     = 5'd15;
    localparam [4:0] CH_I     = 5'd16;
    localparam [4:0] CH_M     = 5'd17;
    localparam [4:0] CH_E     = 5'd18;
    localparam [4:0] CH_B     = 5'd19;
    localparam [4:0] CH_R     = 5'd20;
    localparam [4:0] CH_C     = 5'd21;
    localparam [4:0] CH_N     = 5'd22;
    localparam [4:0] CH_G     = 5'd23;
    localparam [4:0] CH_D     = 5'd26;
    localparam [4:0] CH_S     = 5'd27;

    //-------------------------------------------------------------------------
    // 坐标 → 面板内位置
    //-------------------------------------------------------------------------
    wire in_x = (I_x >= X0) && (I_x < (X0 + PANEL_W));
    wire in_y = (I_y >= Y0) && (I_y < (Y0 + PANEL_H));

    wire [9:0] dx = I_x - X0;
    wire [9:0] dy = I_y - Y0;

    wire [4:0] col   = dx[7:3];                 // 0..19（dx < 160）
    wire [2:0] sub_x = dx[2:0];                 // 字符内列 0..7

    wire       line1 = (dy < 10'd18);                       // 第 1 行
    wire       line3 = (dy >= 10'd36);                      // 第 3 行
    wire       line2 = !line1 && !line3;                    // 第 2 行
    wire [9:0] row_d = line3 ? (dy - 10'd36) :
                       line2 ? (dy - 10'd18) : dy;
    wire [4:0] row5  = row_d[4:0];
    wire       in_row = (row_d < 10'd16);                   // 行间的 2px 空隙不画字

    // 面板内有效像素（de=1 且落在面板矩形内）
    wire in_panel = I_de && in_x && in_y;

    //-------------------------------------------------------------------------
    // 字符选择（排版表）
    //-------------------------------------------------------------------------
    reg [4:0] ch;

    always @(*) begin
        ch = CH_SP;
        if (line1) begin
            // 第 1 行：TIME 00:00 IMG:1/4
            case (col)
                5'd0 : ch = CH_T;
                5'd1 : ch = CH_I;
                5'd2 : ch = CH_M;
                5'd3 : ch = CH_E;
                5'd4 : ch = CH_SP;
                5'd5 : ch = I_mm_hi;
                5'd6 : ch = I_mm_lo;
                5'd7 : ch = CH_COLON;
                5'd8 : ch = I_ss_hi;
                5'd9 : ch = I_ss_lo;
                5'd10: ch = CH_SP;
                5'd11: ch = CH_I;
                5'd12: ch = CH_M;
                5'd13: ch = CH_G;
                5'd14: ch = CH_COLON;
                5'd15: ch = I_img;
                5'd16: ch = CH_SLASH;
                5'd17: ch = CH_4;
                default: ch = CH_SP;
            endcase
        end else if (line2) begin
            // 第 2 行：BRT:+00 CNT:128 TR:0
            case (col)
                5'd0 : ch = CH_B;
                5'd1 : ch = CH_R;
                5'd2 : ch = CH_T;
                5'd3 : ch = CH_COLON;
                5'd4 : ch = I_brt_sign;
                5'd5 : ch = I_brt_hi;
                5'd6 : ch = I_brt_lo;
                5'd7 : ch = CH_SP;
                5'd8 : ch = CH_C;
                5'd9 : ch = CH_N;
                5'd10: ch = CH_T;
                5'd11: ch = CH_COLON;
                5'd12: ch = I_cnt_h;
                5'd13: ch = I_cnt_m;
                5'd14: ch = I_cnt_l;
                5'd15: ch = CH_SP;
                5'd16: ch = CH_T;
                5'd17: ch = CH_R;
                5'd18: ch = CH_COLON;
                5'd19: ch = I_tr;
                default: ch = CH_SP;
            endcase
        end else begin
            // 第 3 行：MDE:1 TMB:1 SRC:0
            case (col)
                5'd0 : ch = CH_M;
                5'd1 : ch = CH_D;
                5'd2 : ch = CH_E;
                5'd3 : ch = CH_COLON;
                5'd4 : ch = I_viz_mode;
                5'd5 : ch = CH_SP;
                5'd6 : ch = CH_T;
                5'd7 : ch = CH_M;
                5'd8 : ch = CH_B;
                5'd9 : ch = CH_COLON;
                5'd10: ch = I_timbre;
                5'd11: ch = CH_SP;
                5'd12: ch = CH_S;
                5'd13: ch = CH_R;
                5'd14: ch = CH_C;
                5'd15: ch = CH_COLON;
                5'd16: ch = I_audio_src;
                default: ch = CH_SP;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 字库查表（组合）
    //-------------------------------------------------------------------------
    wire [7:0] glyph;
    wire       pix_on = glyph[3'd7 - sub_x];    // bit7 = 最左像素

    font_ascii_8x16 u_font (
        .I_code (ch),
        .I_row  (row5[3:0]),
        .O_bits (glyph)
    );

    //-------------------------------------------------------------------------
    // 像素叠加
    //-------------------------------------------------------------------------
    wire [7:0] r_half = {1'b0, I_rgb[23:17]};
    wire [7:0] g_half = {1'b0, I_rgb[15:9]};
    wire [7:0] b_half = {1'b0, I_rgb[7:1]};
    wire [23:0] bg_half = {r_half, g_half, b_half};

    reg [23:0] rgb_mux;

    always @(*) begin
        if (!I_en || !in_panel || !in_row)
            rgb_mux = I_rgb;                    // 直通（关掉 OSD / 面板外 / 行空隙不替换）
        else if (pix_on)
            rgb_mux = 24'hFFFFFF;               // 字形：纯白
        else
            rgb_mux = bg_half;                  // 底：原像素亮度减半
    end

    assign O_de  = I_de;
    assign O_x   = I_x;
    assign O_y   = I_y;
    assign O_rgb = rgb_mux;

endmodule
