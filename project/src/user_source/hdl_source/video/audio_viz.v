//=============================================================================
// audio_viz.v — 音频可视化图层（波形 + 8 段频谱柱）
//-----------------------------------------------------------------------------
// 功能：
//   串在 video_proc 之后、osd_composer 之前的一个叠加图层，纯像素域工作：
//     · 波形：右侧一条示波器曲线（青色 + 2 级渐变阴影，640 点缓冲按 4:1 抽取）
//     · 频谱：右侧 8 根柱子（绿→黄→红三段配色）+ 白色峰值点
//   两个图层同时开、同时关（I_mode = 2'b11 全开 / 2'b00 全关），开关与 OSD 面板共用 K4。
//   I_mode == 0 时模块完全直通，画面与 M2 基线逐像素一致，便于上板对比。
//
//   版面（640×480）：所有图形只占 x=480..639 这条 160px 竖带，左侧 480px
//   主画面完全不参与叠加，避免遮挡正常视频内容。
//     x = 480..639   可视化竖带（宽 160）
//     y = 72..184    波形带（基线 128，幅度 ±56px，下方 10px 渐变阴影）
//     y = 243..435   频谱柱（柱高 = 段值 ×4，0..192px，从 435 向上生长）
//     x = 496..623   8 根柱子，每根占 16px 单元（左右各留 16px 边距）、
//                    柱宽 14px、间隙 2px
//   避让：右上参数面板 x=472..631 / y=8..59、左上 Logo x=8..39、底部滚动
//   字幕 y=444..467，本模块的 y 范围 72..435 与三者均不重叠。
//
// 流水（1 拍）：
//   波形 RAM 读延迟 1 拍，所以本模块把 de/x/y/rgb 一起再打一拍；
//   读地址直接用当前 I_x（组合），读数据正好在 d1_* 有效的同一拍返回，
//   因此"波形叠加层"整体只给视频链增加 1 拍延迟，不破坏同拍关系。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效；I_vs 负极性。
//
// 接口：
//   in  I_mode[1:0]     可视化开关（已在帧边界锁存）：11=波形+频谱同开，00=全关
//   in  I_samp_valid    48kHz 音频样本有效（来自 I2S_receiver）
//   in  I_samp[23:0]    24bit 有符号 PCM
//   in  I_de/I_x/I_y/I_rgb   像素流水
//   out O_de/O_x/O_y/O_rgb   延迟 1 拍后的像素流水
//
// 参数：无
//
// 内部例化：wave_capture（波形采集）、spectrum_analyzer（频谱分析）
//=============================================================================
`timescale 1ns / 1ps

module audio_viz (
    input  wire               I_clk,
    input  wire               I_rst,
    input  wire               I_vs,           // 负极性（场同步）
    input  wire [1:0]         I_mode,
    input  wire               I_samp_valid,
    input  wire signed [23:0] I_samp,

    input  wire               I_de,
    input  wire [9:0]         I_x,
    input  wire [9:0]         I_y,
    input  wire [23:0]        I_rgb,

    output wire               O_de,
    output wire [9:0]         O_x,
    output wire [9:0]         O_y,
    output reg  [23:0]        O_rgb
);

    //-------------------------------------------------------------------------
    // 版面与配色
    //-------------------------------------------------------------------------
    localparam [9:0] X_VIZ0     = 10'd480;    // 可视化竖带左边界
    localparam [9:0] Y_WAVE_BASE= 10'd128;    // 波形基线
    localparam [9:0] Y_WAVE_MIN = 10'd72;     // 波形带上下沿
    localparam [9:0] Y_WAVE_MAX = 10'd184;
    localparam [9:0] Y_BAR_BOT  = 10'd435;    // 柱子底部
    localparam [9:0] Y_SEG_G    = 10'd371;    // 绿色段上界（底部 64px）
    localparam [9:0] Y_SEG_Y    = 10'd307;    // 黄色段上界（再往上 64px）

    localparam [23:0] C_WAVE  = 24'h00FFFF;   // 波形主线（青）
    localparam [23:0] C_SH1   = 24'h0A6A78;   // 阴影近端
    localparam [23:0] C_SH2   = 24'h05323A;   // 阴影远端
    localparam [23:0] C_GREEN = 24'h00E676;   // 柱：低段
    localparam [23:0] C_YELLOW= 24'hFFEA00;   // 柱：中段
    localparam [23:0] C_RED   = 24'hFF1744;   // 柱：高段
    localparam [23:0] C_PEAK  = 24'hFFFFFF;   // 峰值点

    //-------------------------------------------------------------------------
    // vs 下降沿（帧结束），供两个统计模块同步
    //-------------------------------------------------------------------------
    reg  vs_d;
    wire vs_fall = vs_d & ~I_vs;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) vs_d <= 1'b1;
        else       vs_d <= I_vs;
    end

    //-------------------------------------------------------------------------
    // 波形采集 + 频谱分析
    //-------------------------------------------------------------------------
    wire [7:0]  wave_data;
    wire [47:0] bar_vec;
    wire [47:0] peak_vec;

    // 波形读地址：竖带内 x-480 = 0..159，×4 后覆盖整个 640 点缓冲
    // （相当于 4:1 抽取，一屏能看到约 3.5 个周期而不是 0.87 个）。
    // 窗口外地址会越界，wave_capture 内部做了一次 mod 640 与兜底，安全。
    wire [9:0] wx_off     = I_x - X_VIZ0;
    wire [9:0] wave_raddr = {wx_off[7:0], 2'b00};

    wave_capture u_wave (
        .I_clk        (I_clk),
        .I_rst        (I_rst),
        .I_vs_fall    (vs_fall),
        .I_samp_valid (I_samp_valid),
        .I_samp       (I_samp),
        .I_rd_x       (wave_raddr),
        .O_rd_data    (wave_data)
    );

    spectrum_analyzer u_spec (
        .I_clk        (I_clk),
        .I_rst        (I_rst),
        .I_vs_fall    (vs_fall),
        .I_samp_valid (I_samp_valid),
        .I_samp       (I_samp),
        .O_bar        (bar_vec),
        .O_peak       (peak_vec)
    );

    //-------------------------------------------------------------------------
    // 像素流水整体延迟 1 拍（与波形 RAM 读延迟对齐）
    //-------------------------------------------------------------------------
    reg        d1_de;
    reg [9:0]  d1_x;
    reg [9:0]  d1_y;
    reg [23:0] d1_rgb;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            d1_de  <= 1'b0;
            d1_x   <= 10'd0;
            d1_y   <= 10'd0;
            d1_rgb <= 24'd0;
        end
        else begin
            d1_de  <= I_de;
            d1_x   <= I_x;
            d1_y   <= I_y;
            d1_rgb <= I_rgb;
        end
    end

    assign O_de = d1_de;
    assign O_x  = d1_x;
    assign O_y  = d1_y;

    //-------------------------------------------------------------------------
    // 波形几何：8bit 有符号样本 → ±56px 偏移（超限裁切，防止冲出波形带）
    //   样本高 8bit 在 L1（±2e6）/L2（±1.7e6）下都有 ±25..±31，左移 1 位
    //   即可铺满 112px 高的波形带，不放大时会显得过平。
    //-------------------------------------------------------------------------
    wire signed [8:0]  wv   = {{1{wave_data[7]}}, wave_data};
    wire signed [9:0]  wraw = {{1{wv[8]}}, wv} <<< 1;                 // ±60
    wire signed [9:0]  woff = (wraw >  10'sd56) ?  10'sd56 :
                              (wraw < -10'sd56) ? -10'sd56 : wraw;
    // 混合有/无符号运算得到的是模 2^11 的无符号数，取低 10 位正好是屏幕坐标
    wire        [10:0] y_wave_u = {1'b0, Y_WAVE_BASE} - {{1{woff[9]}}, woff};
    wire        [9:0]  y_wave   = y_wave_u[9:0];

    wire in_viz_x     = (d1_x >= X_VIZ0);
    wire in_wave_band = in_viz_x && (d1_y >= Y_WAVE_MIN) && (d1_y <= Y_WAVE_MAX);
    wire on_wave      = (d1_y == y_wave);
    wire [9:0] sh_d   = d1_y - y_wave;
    wire in_shadow    = (d1_y > y_wave) && (sh_d <= 10'd10);
    wire shadow_near  = (sh_d <= 10'd3);

    //-------------------------------------------------------------------------
    // 频谱柱几何：竖带内 x-480 → 16px 单元，只画 1..8 号单元（左右各留 16px）
    //-------------------------------------------------------------------------
    wire [9:0] bx        = d1_x - X_VIZ0;
    wire [3:0] cx        = bx[7:4];
    wire       in_cell   = in_viz_x && (cx >= 4'd1) && (cx <= 4'd8);
    wire [2:0] bk        = cx[2:0] - 3'd1;
    wire       in_bar_col= in_cell && (bx[3:0] < 4'd14);

    reg [5:0] bh;   // 本列柱高
    reg [5:0] ph;   // 本列峰值
    always @(*) begin
        case (bk)
            3'd0: begin bh = bar_vec[5:0];   ph = peak_vec[5:0];   end
            3'd1: begin bh = bar_vec[11:6];  ph = peak_vec[11:6];  end
            3'd2: begin bh = bar_vec[17:12]; ph = peak_vec[17:12]; end
            3'd3: begin bh = bar_vec[23:18]; ph = peak_vec[23:18]; end
            3'd4: begin bh = bar_vec[29:24]; ph = peak_vec[29:24]; end
            3'd5: begin bh = bar_vec[35:30]; ph = peak_vec[35:30]; end
            3'd6: begin bh = bar_vec[41:36]; ph = peak_vec[41:36]; end
            default: begin bh = bar_vec[47:42]; ph = peak_vec[47:42]; end
        endcase
    end

    // 柱高 = 段值 ×4（6bit → 0..192px），纵向空间变大后才有"频谱"的观感
    wire [9:0] bh_px   = {2'b00, bh, 2'b00};
    wire [9:0] bar_top = Y_BAR_BOT - bh_px + 10'd1;
    wire on_bar  = in_bar_col && (bh != 6'd0) &&
                   (d1_y >= bar_top) && (d1_y <= Y_BAR_BOT);

    wire [9:0] pk_px   = {2'b00, ph, 2'b00};
    wire [9:0] pk_y    = Y_BAR_BOT - pk_px;
    wire on_peak = in_bar_col && (ph != 6'd0) &&
                   ((d1_y == pk_y) || (d1_y == pk_y - 10'd1));

    wire [23:0] bar_col = (d1_y >= Y_SEG_G) ? C_GREEN :
                          (d1_y >= Y_SEG_Y) ? C_YELLOW : C_RED;

    // 阴影用原像素压暗后再染色，保证不改变原图亮度层次
    wire [23:0] dim    = {1'b0, d1_rgb[23:17],
                          1'b0, d1_rgb[15:9],
                          1'b0, d1_rgb[7:1]};
    wire [23:0] shade1 = dim | C_SH1;
    wire [23:0] shade2 = dim | C_SH2;

    //-------------------------------------------------------------------------
    // 叠加输出（组合，0 拍；整体延迟已由 d1_* 提供）
    //-------------------------------------------------------------------------
    always @(*) begin
        O_rgb = d1_rgb;
        if (d1_de) begin
            if (I_mode[1]) begin
                if (on_peak)      O_rgb = C_PEAK;
                else if (on_bar)  O_rgb = bar_col;
            end
            if (I_mode[0] && in_wave_band) begin
                if (on_wave)               O_rgb = C_WAVE;
                else if (in_shadow)
                    O_rgb = shadow_near ? shade1 : shade2;
            end
        end
    end

endmodule
