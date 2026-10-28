//=============================================================================
// audio_viz.v — 音频可视化图层（波形 + 8 段频谱柱）
//-----------------------------------------------------------------------------
// 功能：
//   串在 video_proc 之后、osd_composer 之前的一个叠加图层，纯像素域工作：
//     · 波形：屏幕中下部一条 640 点示波器曲线（青色 + 2 级渐变阴影）
//     · 频谱：底部 8 根柱子（绿→黄→红三段配色）+ 白色峰值点
//   两个图层可以独立开关（I_mode[0] = 波形，I_mode[1] = 频谱）。
//   I_mode == 0 时模块完全直通，画面与 M2 基线逐像素一致，便于上板对比。
//
//   版面（640×480，与滚动字幕 y=444..467 严格避让）：
//     y = 352..384   波形带（基线 368，幅度 ±16px 后裁切）
//     y = 391..439   频谱柱（柱高 0..48px，从 439 向上生长）
//     x = 128..511   8 根柱子，每根占 64px 单元、柱宽 60px、间隙 4px
//
// 流水（1 拍）：
//   波形 RAM 读延迟 1 拍，所以本模块把 de/x/y/rgb 一起再打一拍；
//   读地址直接用当前 I_x（组合），读数据正好在 d1_* 有效的同一拍返回，
//   因此"波形叠加层"整体只给视频链增加 1 拍延迟，不破坏同拍关系。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效；I_vs 负极性。
//
// 接口：
//   in  I_mode[1:0]     可视化模式（已在帧边界锁存）
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
    localparam [9:0] Y_WAVE_BASE = 10'd368;   // 波形基线
    localparam [9:0] Y_WAVE_MIN  = 10'd352;   // 波形带上下沿
    localparam [9:0] Y_WAVE_MAX  = 10'd384;
    localparam [9:0] Y_BAR_BOT   = 10'd439;   // 柱子底部
    localparam [9:0] AMP_LIMIT   = 10'd16;    // 波形最大偏移（±16px）

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

    wave_capture u_wave (
        .I_clk        (I_clk),
        .I_rst        (I_rst),
        .I_vs_fall    (vs_fall),
        .I_samp_valid (I_samp_valid),
        .I_samp       (I_samp),
        .I_rd_x       (I_x),
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
    // 波形几何：8bit 有符号样本 → ±16px 偏移（超限裁切，防止冲出波形带）
    //-------------------------------------------------------------------------
    wire signed [8:0]  wv   = {{1{wave_data[7]}}, wave_data};
    wire signed [9:0]  wraw = {{1{wv[8]}}, wv} >>> 1;                 // ±63
    wire signed [9:0]  woff = (wraw >  10'sd16) ?  10'sd16 :
                              (wraw < -10'sd16) ? -10'sd16 : wraw;
    wire signed [10:0] y_wave_s = 11'sd368 - {{1{woff[9]}}, woff};
    wire        [9:0]  y_wave   = y_wave_s[9:0];

    wire in_wave_band = (d1_y >= Y_WAVE_MIN) && (d1_y <= Y_WAVE_MAX);
    wire on_wave      = (d1_y == y_wave);
    wire in_shadow    = (d1_y > y_wave) && (d1_y <= Y_WAVE_MAX);
    wire shadow_near  = ((d1_y - y_wave) <= 10'd2);

    //-------------------------------------------------------------------------
    // 频谱柱几何：x/64 → 单元号，仅 2..9 号单元画柱
    //-------------------------------------------------------------------------
    wire [3:0] cx        = d1_x[9:6];
    wire       in_cell   = (cx >= 4'd2) && (cx <= 4'd9);
    wire [2:0] bk        = cx[2:0] - 3'd2;
    wire       in_bar_col= in_cell && (d1_x[5:0] < 6'd60);

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

    wire [9:0] bar_top = Y_BAR_BOT - {4'd0, bh} + 10'd1;
    wire on_bar  = in_bar_col && (bh != 6'd0) &&
                   (d1_y >= bar_top) && (d1_y <= Y_BAR_BOT);

    wire [9:0] pk_y    = Y_BAR_BOT - {4'd0, ph};
    wire on_peak = in_bar_col && (ph != 6'd0) &&
                   ((d1_y == pk_y) || (d1_y == pk_y - 10'd1));

    wire [23:0] bar_col = (d1_y >= 10'd424) ? C_GREEN :
                          (d1_y >= 10'd408) ? C_YELLOW : C_RED;

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
