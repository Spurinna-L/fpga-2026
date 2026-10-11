//=============================================================================
// wav_r2r_top.v  —  WAV 播放（BRAM 版）总装顶层
//-----------------------------------------------------------------------------
//  把三个子模块串起来，完成你要的整条链路：
//
//     .wav 字节流 ──▶ wav_to_pcm ──16bit PCM+写地址──▶ audio_bram
//                                                        │ 读出采样
//                                                        ▼
//                                              r2r_dac_player ──▶ dac_out[7:0] ──▶ R-2R DAC
//
//  ┌─────────────┐  s_valid/s_data    ┌────────────┐ wr_*  ┌────────────┐
//  │ FAT/SD 前端 │───────────────────▶│ wav_to_pcm │──────▶│ audio_bram │
//  │ (字节流)     │◀──── s_ready ──────│            │       │            │
//  └─────────────┘                    └─────┬──────┘       └─────┬──────┘
//                                 sample_count │                  │ rd_data
//                                              ▼                  ▼
//                                        ┌───────────────────────────┐
//                                        │ r2r_dac_player            │
//                                        │ (48kHz 环形读出→音量→R-2R) │
//                                        └─────────────┬─────────────┘
//                                                      ▼
//                                                  dac_out[7:0]
//
// ============================================================================
// 怎么接上游（SD 卡 → WAV 字节流）？
// ============================================================================
//  本顶层的上游接口是「字节流握手」：s_valid / s_data / s_ready。
//  规则：s_valid=1 且 s_ready=1 的时钟沿 = 消费掉 s_data 这个字节。
//
//  接法一（推荐，等 fat32_reader 实现后）：
//      fat32_reader 解析出目标 .wav 文件后，把它输出的
//         file_data  → s_data
//         file_valid → s_valid
//         file_pop   ← s_ready   （s_ready 当"取走这个字节"用；若前端是
//                                 show-ahead 语义，就把 s_ready 直接当 pop）
//
//  接法二（快速自测 / 仿真）：
//      用一个 ROM 或仿真波形，把一段 WAV 文件的字节按顺序喂到 s_data，
//      配合 s_valid 即可（见 sim/tb_wav_r2r.v）。
//
//  接法三（直接连 sd_ctrl 输出的字节 FIFO）：
//      sd_ctrl 的 rd_data → s_data，rd_valid → s_valid，s_ready → rd_pop。
//      （注意此时吐的是"整个扇区"的裸字节，需要前面还有 FAT/文件定位；
//       所以正式播放请用接法一。）
//
// ============================================================================
// 播放流程（流式·边读边解码边播）
//   上电 → 复位释放 → 字节流灌入 → 解析 fmt 拿到采样率/声道/位宽
//        → 解析 data 把 PCM 写入 BRAM（写指针回卷，边收边写）
//        → 缓冲彖够领先量→ 播放器开始按 48kHz 环形读取 → R-2R DAC 输出
//        → 缓冲快满时拉高 bp_pause 让上游暂停（背压），排空后恢复
//        → 文件读完(load_done)且缓冲排空 → 停机
//
// 参数：
//   AW          : BRAM 地址位宽（=环形缓冲深度）。AW=13 → 8192 个采样 ≈ 0.17s@48kHz；
//                 AW=15 → 32768 个采样 ≈ 0.68s。它只是“能彖多少领先量”，
//                 不再限制音频总时长（流式播放，总长可任意）。
//   CLK_HZ      : 工作时钟频率
//   SAMPLE_HZ   : 播放采样率（一般 48kHz；若想按文件里的原始采样率播放，
//                 可把 sample_rate 接到本参数——但那需要动态分频，此处固定）
//   流控门限（FILL_HIGH / FILL_LOW / START_LEAD）见下面第 0) 节。
//=============================================================================
`timescale 1ns / 1ps

module wav_r2r_top #(
    parameter integer AW        = 15,
    parameter integer CLK_HZ    = 50_000_000,
    parameter integer SAMPLE_HZ = 48_000
)(
    input  wire          clk,             // 工作时钟（接 50MHz）
    input  wire          rst_n,           // 低有效复位

    // ---------- 上游：WAV 文件字节流（来自 SD/FAT）----------
    input  wire          s_valid,
    input  wire [7:0]    s_data,
    output wire          s_ready,

    // ---------- 控制 ----------
    input  wire [7:0]    volume,          // 数字音量 0..255

    // ---------- 输出：板载 R-2R DAC ----------
    output wire [7:0]    dac_out,         // B14,B15,B16,C15,C16,E13,E16,F16

    // ---------- 状态（可选：接数码管/LED 显示）----------
    output wire          header_ok,
    output wire          load_done,
    output wire [31:0]   sample_count,
    output wire [31:0]   sample_rate,
    output wire [15:0]   channels,
    output wire [15:0]   bits
);

    //-------------------------------------------------------------------------
    // 0) 环形缓冲流控（流式播放的核心）
    //    BRAM 被当作"环形缓冲(ring buffer)"：写指针由 wav_to_pcm 推进、
    //    读指针由播放器推进，二者各自回卷、互不等待——这就是"边读边播"。
    //        fill = sample_count - rd_count   （缓冲里"已写入但还没读走"的采样数）
    //    高低水位背压（防止写指针追过读指针，把未播的数据覆盖掉）：
    //        fill 升到高水位 → bp_pause=1 → 让上游(wav_to_pcm→FAT/SD)暂停送字节；
    //        fill 降到低水位 → bp_pause=0 → 恢复送字节。
    //    领先量启动（防止刚开播就断音）：
    //        fill 攒够 START_LEAD 个采样（或文件已读完）才开播。
    //-------------------------------------------------------------------------
    wire [31:0] rd_count;                          // 播放器已读出的采样总数
    wire [31:0] fill = sample_count - rd_count;    // 环形缓冲里"可读"的采样数

    localparam [31:0] FILL_HIGH  = (1 << AW) - 16; // 高水位（留 16 个样本余量）
    localparam [31:0] FILL_LOW   = (1 << AW) >> 1; // 低水位（半满）
    localparam [31:0] START_LEAD = 32'd256;        // 启动领先量（≈5ms @48kHz）

    reg bp_pause;                                  // → wav_to_pcm 背压
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bp_pause <= 1'b0;
        else if (fill >= FILL_HIGH)
            bp_pause <= 1'b1;                      // 快满了：暂停上游
        else if (fill <= FILL_LOW)
            bp_pause <= 1'b0;                      // 排空了：恢复上游
    end

    // 启动条件：缓冲攒够领先量，或整个文件已读完（短文件也要能播）
    wire start = load_done | (fill >= START_LEAD);

    //-------------------------------------------------------------------------
    // 1) WAV 解析：字节流 → 16bit PCM（写 BRAM，边收边写）
    //-------------------------------------------------------------------------
    wire          we;
    wire [AW-1:0] wr_addr;
    wire [15:0]   wr_data;

    wav_to_pcm #(
        .AW   (AW),
        .DEPTH(1 << AW)
    ) u_wav_to_pcm (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_valid      (s_valid),      // ← 上游文件字节流：字节有效
        .s_data       (s_data),       // ← 上游文件字节流：1 个字节
        .s_ready      (s_ready),      // → 回给上游：可以收字节
        .bp_pause     (bp_pause),     // ← 背压：缓冲快满时暂停收字节
        .bram_we      (we),           // → BRAM 写使能
        .bram_addr    (wr_addr),      // → BRAM 写地址
        .bram_data    (wr_data),      // → BRAM 写数据（16bit PCM）
        .sample_count (sample_count), // → 已写入的采样个数
        .sample_rate  (sample_rate),  // → 解析出的采样率
        .channels     (channels),     // → 解析出的声道数
        .bits         (bits),         // → 解析出的位宽
        .header_ok    (header_ok),    // → 头部解析成功标志
        .load_done    (load_done),    // → data 块读完
        .load_active  ()              // 未使用
    );

    //-------------------------------------------------------------------------
    // 2) 采样存储：双口 BRAM
    //-------------------------------------------------------------------------
    wire [AW-1:0] rd_addr;
    wire [15:0]   rd_data;

    audio_bram #(
        .AW   (AW),
        .DEPTH(1 << AW)
    ) u_audio_bram (
        .wr_clk  (clk),
        .wr_en   (we),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_clk  (clk),
        .rd_en   (1'b1),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    //-------------------------------------------------------------------------
    // 3) 播放器：环形缓冲读出 → 音量 → R-2R DAC（流式）
    //-------------------------------------------------------------------------
    wire [AW-1:0] player_addr;

    r2r_dac_player #(
        .CLK_HZ    (CLK_HZ),
        .SAMPLE_HZ (SAMPLE_HZ),
        .AW        (AW),
        .DEPTH     (1 << AW)
    ) u_player (
        .clk          (clk),
        .rst_n        (rst_n),
        .bram_addr    (player_addr),  // → BRAM 读地址（环形）
        .bram_data    (rd_data),      // ← BRAM 读出的采样
        .fill         (fill),         // ← 可读采样数（决定能否读、是否断音）
        .start        (start),        // ← 启动播放（领先量到位或文件已读完）
        .eof          (load_done),    // ← 文件已全部进缓冲（播完即可停机）
        .rd_count     (rd_count),     // → 回给顶层，用于计算 fill
        .volume       (volume),       // ← 数字音量
        .dac_out      (dac_out)       // → 8bit R-2R DAC 码
    );

    assign rd_addr = player_addr;

endmodule
