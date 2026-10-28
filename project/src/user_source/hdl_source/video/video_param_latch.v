//=============================================================================
// video_param_latch.v — 参数跨时钟域（50MHz 按键域 → 25MHz 像素域）
//-----------------------------------------------------------------------------
// 功能：
//   把 50MHz 域的一组视频参数安全地送到 video_clk 像素域，并顺便把
//   数值转换成 OSD 需要的「字符码」，供 osd_composer 直接查字库。
//
//   为什么不能直接打两拍就完事：
//     brightness / contrast 都是多位总线。用多个触发器分别同步时，
//     如果总线恰好在采样窗口内翻转，不同的位可能被采到「新旧混合」的
//     中间值（例如亮度 8→16 中间出现 24、对比度 127→128 出现 63），
//     画面会闪一下错色。
//   本模块的做法：
//     1) 总线整体 2FF 同步；
//     2) 连续检测「总线两次采样完全相同」，累计到 STABLE_N 拍才认为稳定；
//     3) 只在 vs 帧边界且总线稳定时，才整组锁存到输出寄存器。
//     这样输出值永远是「某一帧开始前的完整快照」，绝不会出现中间码。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效；I_vs 负极性（低有效）。
//
// 接口（输入均为 50MHz 域）：
//   I_brightness signed[7:0]  亮度 -64..+64
//   I_contrast[7:0]           对比度 64..192
//   I_osd_en                   OSD 总开关
//   I_subtitle_en             底部滚动字幕开关（K13）
//   I_trans_mode[1:0]          转场模式 0..2
//   I_viz_mode[1:0]            音频可视化模式 0..3（bit0 波形 / bit1 频谱柱）
//   I_img_idx[1:0]             当前图片序号 0..3
//   I_time_mm / I_time_ss[7:0] 上电计时
//
// 输出（像素域，帧内恒定）：
//   O_brightness / O_contrast / O_osd_en / O_subtitle_en / O_trans_mode
//   O_viz_mode                 原样供 video_proc / audio_viz / 字幕图层使用
//   O_ch_*[4:0]                 OSD 字符码（见 font_ascii_8x16.v 码表）
//
// 字符码约定（与 font_ascii_8x16.v 严格一致）：
//   0..9 = '0'..'9'，10 = ':'，11 = '/'，12 = '+'，13 = '-'，14 = 空格
//   15='T' 16='I' 17='M' 18='E' 19='B' 20='R' 21='C' 22='N' 23='G'
//   24='A' 25='F' 26='D' 27='S' 28='P' 29='O' 30='L' 31='.'
//
// 参数：
//   STABLE_N = 4'd8   总线需连续稳定的像素时钟拍数（25MHz 下约 0.32us）
//
// 内部例化：无
//
// 备注：
//   上电默认值与 regs.v 的复位值保持一致：亮度 0、对比度 128、OSD 开。
//   在总线稳定计数达标之前不锁存，避免把复位过程中的 0 值（对比度 0 = 全黑）
//   误采进画面。
//=============================================================================
`timescale 1ns / 1ps

module video_param_latch #(
    parameter [3:0] STABLE_N = 4'd8
)(
    input  wire               I_clk,
    input  wire               I_rst,          // 高有效
    input  wire               I_vs,           // 负极性

    // ---- 50MHz 域原始参数 ----
    input  wire signed [7:0]  I_brightness,
    input  wire [7:0]         I_contrast,
    input  wire               I_osd_en,
    input  wire               I_subtitle_en,
    input  wire [1:0]         I_trans_mode,
    input  wire [1:0]         I_viz_mode,
    input  wire [1:0]         I_img_idx,
    input  wire [7:0]         I_time_mm,
    input  wire [7:0]         I_time_ss,

    // ---- 像素域锁存结果 ----
    output reg  signed [7:0]  O_brightness,
    output reg  [7:0]         O_contrast,
    output reg                O_osd_en,
    output reg                O_subtitle_en,
    output reg  [1:0]         O_trans_mode,
    output reg  [1:0]         O_viz_mode,

    // ---- OSD 字符码 ----
    output reg  [4:0]         O_ch_brt_sign,  // '+' 或 '-'
    output reg  [4:0]         O_ch_brt_hi,    // 亮度绝对值十位
    output reg  [4:0]         O_ch_brt_lo,    // 亮度绝对值个位
    output reg  [4:0]         O_ch_cnt_h,     // 对比度百位
    output reg  [4:0]         O_ch_cnt_m,     // 对比度十位
    output reg  [4:0]         O_ch_cnt_l,     // 对比度个位
    output reg  [4:0]         O_ch_mm_hi,     // 分钟十位
    output reg  [4:0]         O_ch_mm_lo,     // 分钟个位
    output reg  [4:0]         O_ch_ss_hi,     // 秒钟十位
    output reg  [4:0]         O_ch_ss_lo,     // 秒钟个位
    output reg  [4:0]         O_ch_img,       // 图片号 1..4
    output reg  [4:0]         O_ch_tr         // 转场模式 0..2
);

    //-------------------------------------------------------------------------
    // 参数总线打包（顺序固定，只用于「整体是否变化」的比较和整组锁存）
    //-------------------------------------------------------------------------
    wire [39:0] prm_bus = {
        I_viz_mode,     // [39:38]
        I_brightness,   // [37:30]
        I_contrast,     // [29:22]
        I_osd_en,       // [21]
        I_subtitle_en,  // [20]
        I_trans_mode,   // [19:18]
        I_img_idx,      // [17:16]
        I_time_mm,      // [15:8]
        I_time_ss       // [7:0]
    };

    //-------------------------------------------------------------------------
    // 2FF 同步 + 稳定检测
    //-------------------------------------------------------------------------
    reg [39:0] sync0, sync1, sync1_d;
    reg [3:0]  stable_cnt;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            sync0      <= 40'd0;
            sync1      <= 40'd0;
            sync1_d    <= 40'd0;
            stable_cnt <= 4'd0;
        end else begin
            sync0   <= prm_bus;
            sync1   <= sync0;
            sync1_d <= sync1;
            if (sync1 != sync1_d)
                stable_cnt <= 4'd0;                     // 总线刚变化
            else if (stable_cnt != STABLE_N)
                stable_cnt <= stable_cnt + 4'd1;        // 连续稳定计数
        end
    end

    wire prm_stable = (stable_cnt == STABLE_N) && (sync1 == sync1_d);

    //-------------------------------------------------------------------------
    // vs 帧边界（负极性下降沿）
    //-------------------------------------------------------------------------
    reg  vs_d;
    wire vs_fall = vs_d & ~I_vs;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)
            vs_d <= 1'b1;
        else
            vs_d <= I_vs;
    end

    //-------------------------------------------------------------------------
    // 从稳定快照中拆出各参数
    //-------------------------------------------------------------------------
    wire signed [7:0] br  = sync1[37:30];
    wire [7:0]        cnt = sync1[29:22];
    wire              en  = sync1[21];
    wire              sub = sync1[20];
    wire [1:0]        trm = sync1[19:18];
    wire [1:0]        viz = sync1[39:38];
    wire [1:0]        img = sync1[17:16];
    wire [7:0]        mm  = sync1[15:8];
    wire [7:0]        ss  = sync1[7:0];

    // 亮度绝对值（-64..+64 → 0..64），取负需要先把 signed 扩到 8bit
    wire signed [7:0]  br_abs_s = (br < 8'sd0) ? (8'sd0 - br) : br;
    wire        [6:0]  br_abs   = br_abs_s[6:0];

    // 十进制拆分（常数除法，综合器会优化成乘法+移位）
    wire [3:0] br_hi = br_abs / 7'd10;
    wire [3:0] br_lo = br_abs % 7'd10;

    wire [3:0] cnt_h = cnt / 8'd100;              // 0 或 1
    wire [6:0] cnt_r = cnt % 8'd100;
    wire [3:0] cnt_m = cnt_r / 7'd10;
    wire [3:0] cnt_l = cnt_r % 7'd10;

    wire [3:0] mm_hi = mm / 8'd10;
    wire [3:0] mm_lo = mm % 8'd10;
    wire [3:0] ss_hi = ss / 8'd10;
    wire [3:0] ss_lo = ss % 8'd10;

    wire [4:0] img_ch = {3'd0, img} + 5'd1;       // 0..3 → '1'..'4'

    //-------------------------------------------------------------------------
    // 帧边界整组锁存
    //-------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_brightness <= 8'sd0;
            O_contrast   <= 8'd128;
            O_osd_en     <= 1'b1;
            O_subtitle_en <= 1'b1;
            O_trans_mode <= 2'd0;
            O_viz_mode   <= 2'd3;

            O_ch_brt_sign <= 5'd12;   // '+'
            O_ch_brt_hi   <= 5'd0;
            O_ch_brt_lo   <= 5'd0;
            O_ch_cnt_h    <= 5'd1;
            O_ch_cnt_m    <= 5'd2;
            O_ch_cnt_l    <= 5'd8;
            O_ch_mm_hi    <= 5'd0;
            O_ch_mm_lo    <= 5'd0;
            O_ch_ss_hi    <= 5'd0;
            O_ch_ss_lo    <= 5'd0;
            O_ch_img      <= 5'd1;
            O_ch_tr       <= 5'd0;
        end else if (vs_fall && prm_stable) begin
            O_brightness <= br;
            O_contrast   <= cnt;
            O_osd_en     <= en;
            O_subtitle_en <= sub;
            O_trans_mode <= trm;
            O_viz_mode   <= viz;

            O_ch_brt_sign <= (br < 8'sd0) ? 5'd13 : 5'd12;   // '-' : '+'
            O_ch_brt_hi   <= {1'b0, br_hi};
            O_ch_brt_lo   <= {1'b0, br_lo};
            O_ch_cnt_h    <= {1'b0, cnt_h};
            O_ch_cnt_m    <= {1'b0, cnt_m};
            O_ch_cnt_l    <= {1'b0, cnt_l};
            O_ch_mm_hi    <= {1'b0, mm_hi};
            O_ch_mm_lo    <= {1'b0, mm_lo};
            O_ch_ss_hi    <= {1'b0, ss_hi};
            O_ch_ss_lo    <= {1'b0, ss_lo};
            O_ch_img      <= img_ch;
            O_ch_tr       <= {3'd0, trm};
        end
    end

endmodule
