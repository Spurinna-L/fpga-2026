`timescale 1ns/1ps
//=============================================================================
// video_post.v — mixer 之后的视频后处理挂载点（M2 协作边界）
//-----------------------------------------------------------------------------
// 本版已完成 M2 扩展④：实时亮度/对比度 + 参数 OSD 字符面板 + 左上角 Logo 图层。
// 扩展⑤：底部中文滚动字幕（scroll_text_overlay，K13 开关）。
// 链路：rgb_in → video_proc（2 拍）→ osd_composer（组合）→ logo_overlay（组合）
//        → scroll_text_overlay（组合）→ rgb_out
//   - 输入 rgb_in/hs_in/vs_in/de_in/x_in/y_in 已与 mixer 输出严格同拍；
//   - 输出 rgb_out/hs_out/vs_out/de_out/x_out/y_out 与输入相差 2 拍；
//   - hs/vs 在模块内一起延迟 2 拍，与 de/x/y/rgb 保持同拍；
//   - osd_composer / logo_overlay / scroll_text_overlay 都是**纯组合**（0 拍），
//     所以这些叠加级不改变上面的 2 拍对齐关系，对帧缓存/行缓冲/转场完全无影响。
//
// 开关策略：右上角参数面板与左上角 Logo **共用同一个开关**（K4 → osd_en）。
//   logo_overlay 用的也是 prm_osd_en（而不是原始 osd_en），好处：
//     ① 两个图层共用同一份已同步信号，不会因跨时钟域采样时刻不同而错位；
//     ② 都在 video_param_latch 的 vs 帧边界整组锁存后生效，同时开关，无撕裂。
//
// 参数输入均为慢变量（按键/1Hz），模块内部由 video_param_latch 做
// 「2FF + 连续稳定检测 + vs 帧边界整组锁存」后再消费。
//=============================================================================
module video_post (
    input  wire        clk,
    input  wire        rst,

    input  wire [23:0] rgb_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [9:0]  x_in,
    input  wire [9:0]  y_in,

    input  wire signed [7:0] brightness,
    input  wire [7:0]        contrast,
    input  wire              osd_en,        // 参数面板 + Logo 共用的总开关
    input  wire              subtitle_en,   // 底部滚动字幕开关（K13）
    input  wire [7:0]        time_mm,
    input  wire [7:0]        time_ss,
    input  wire [1:0]        img_idx,
    input  wire [1:0]        trans_mode,
    input  wire [1:0]        audio_src,

    output wire [23:0] rgb_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    output wire [9:0]  x_out,
    output wire [9:0]  y_out
);

    //-------------------------------------------------------------------------
    // ① 参数跨时钟域（50MHz 按键域 → 25MHz 像素域）
    //    2FF + 连续稳定检测 + vs 帧边界整组锁存，杜绝多位总线中间码
    //-------------------------------------------------------------------------
    wire signed [7:0] prm_brightness;
    wire [7:0]        prm_contrast;
    wire              prm_osd_en;
    wire              prm_subtitle_en;
    wire [1:0]        prm_trans_mode;

    wire [4:0] ch_brt_sign, ch_brt_hi, ch_brt_lo;
    wire [4:0] ch_cnt_h, ch_cnt_m, ch_cnt_l;
    wire [4:0] ch_mm_hi, ch_mm_lo, ch_ss_hi, ch_ss_lo;
    wire [4:0] ch_img, ch_tr;

    video_param_latch u_prm (
        .I_clk        (clk),
        .I_rst        (rst),
        .I_vs         (vs_in),
        .I_brightness (brightness),
        .I_contrast   (contrast),
        .I_osd_en     (osd_en),
        .I_subtitle_en(subtitle_en),
        .I_trans_mode (trans_mode),
        .I_img_idx    (img_idx),
        .I_time_mm    (time_mm),
        .I_time_ss    (time_ss),
        .O_brightness (prm_brightness),
        .O_contrast   (prm_contrast),
        .O_osd_en     (prm_osd_en),
        .O_subtitle_en(prm_subtitle_en),
        .O_trans_mode (prm_trans_mode),
        .O_ch_brt_sign(ch_brt_sign),
        .O_ch_brt_hi  (ch_brt_hi),
        .O_ch_brt_lo  (ch_brt_lo),
        .O_ch_cnt_h   (ch_cnt_h),
        .O_ch_cnt_m   (ch_cnt_m),
        .O_ch_cnt_l   (ch_cnt_l),
        .O_ch_mm_hi   (ch_mm_hi),
        .O_ch_mm_lo   (ch_mm_lo),
        .O_ch_ss_hi   (ch_ss_hi),
        .O_ch_ss_lo   (ch_ss_lo),
        .O_ch_img     (ch_img),
        .O_ch_tr      (ch_tr)
    );

    //-------------------------------------------------------------------------
    // ② 亮度 / 对比度（2 拍流水：第 1 拍乘法，第 2 拍加法+饱和）
    //    de/x/y 用同样的 2 拍寄存器跟随，输出端仍严格同拍
    //-------------------------------------------------------------------------
    wire        proc_de;
    wire [9:0]  proc_x, proc_y;
    wire [23:0] proc_rgb;

    video_proc u_proc (
        .I_clk        (clk),
        .I_rst        (rst),
        .I_de         (de_in),
        .I_x          (x_in),
        .I_y          (y_in),
        .I_rgb        (rgb_in),
        .I_brightness (prm_brightness),
        .I_contrast   (prm_contrast),
        .O_de         (proc_de),
        .O_x          (proc_x),
        .O_y          (proc_y),
        .O_rgb        (proc_rgb)
    );

    //-------------------------------------------------------------------------
    // ③ 参数 OSD（组合叠加，右上角两行字符面板）
    //-------------------------------------------------------------------------
    wire        osd_de;
    wire [9:0]  osd_x, osd_y;
    wire [23:0] osd_rgb;

    osd_composer u_osd (
        .I_de       (proc_de),
        .I_x        (proc_x),
        .I_y        (proc_y),
        .I_rgb      (proc_rgb),
        .I_en       (prm_osd_en),
        .I_brt_sign (ch_brt_sign),
        .I_brt_hi   (ch_brt_hi),
        .I_brt_lo   (ch_brt_lo),
        .I_cnt_h    (ch_cnt_h),
        .I_cnt_m    (ch_cnt_m),
        .I_cnt_l    (ch_cnt_l),
        .I_mm_hi    (ch_mm_hi),
        .I_mm_lo    (ch_mm_lo),
        .I_ss_hi    (ch_ss_hi),
        .I_ss_lo    (ch_ss_lo),
        .I_img      (ch_img),
        .I_tr       (ch_tr),
        .O_de       (osd_de),
        .O_x        (osd_x),
        .O_y        (osd_y),
        .O_rgb      (osd_rgb)
    );

    //-------------------------------------------------------------------------
    // ④ 左上角 Logo 水印图层（组合叠加，0 拍；不影响原图与转场）
    //    开关与右上角参数面板共用 prm_osd_en：同一帧边界同时出现/消失
    //-------------------------------------------------------------------------
    wire        lg_de;
    wire [9:0]  lg_x, lg_y;
    wire [23:0] lg_rgb;

    logo_overlay u_logo (
        .I_de  (osd_de),
        .I_x   (osd_x),
        .I_y   (osd_y),
        .I_rgb (osd_rgb),
        .I_en  (prm_osd_en),
        .O_de  (lg_de),
        .O_x   (lg_x),
        .O_y   (lg_y),
        .O_rgb (lg_rgb)
    );

    //-------------------------------------------------------------------------
    // ⑤ 底部中文滚动字幕（纯组合叠加，0 拍；K13 独立开关）
    //    位置在模块内部按 vs 帧边界更新，开关同样经过帧边界同步，
    //    因此打开/关闭时不会出现半帧错位。关闭时滚动暂停。
    //-------------------------------------------------------------------------
    wire        st_de;
    wire [9:0]  st_x, st_y;
    wire [23:0] st_rgb;

    scroll_text_overlay u_scroll (
        .I_clk (clk),
        .I_rst (rst),
        .I_vs  (vs_in),
        .I_de  (lg_de),
        .I_x   (lg_x),
        .I_y   (lg_y),
        .I_rgb (lg_rgb),
        .I_en  (prm_subtitle_en),
        .O_de  (st_de),
        .O_x   (st_x),
        .O_y   (st_y),
        .O_rgb (st_rgb)
    );

    //-------------------------------------------------------------------------
    // ⑥ hs/vs 跟随 video_proc 的 2 拍延迟，保证全部边带同拍
    //-------------------------------------------------------------------------
    reg hs_d1, hs_d2, vs_d1, vs_d2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hs_d1 <= 1'b1;
            hs_d2 <= 1'b1;
            vs_d1 <= 1'b1;
            vs_d2 <= 1'b1;
        end else begin
            hs_d1 <= hs_in;
            hs_d2 <= hs_d1;
            vs_d1 <= vs_in;
            vs_d2 <= vs_d1;
        end
    end

    assign rgb_out = st_rgb;
    assign de_out  = st_de;
    assign x_out   = st_x;
    assign y_out   = st_y;
    assign hs_out  = hs_d2;
    assign vs_out  = vs_d2;

endmodule
