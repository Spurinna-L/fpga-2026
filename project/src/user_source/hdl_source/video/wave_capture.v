//=============================================================================
// wave_capture.v — 音频波形采集（过零锁相，640 点 × 8bit 双口 RAM）
//-----------------------------------------------------------------------------
// 功能：
//   把 48kHz 音频样本连续写入一片 640×8bit 的简单双口 RAM（循环覆盖），
//   同时在"负→正过零"处打一个取景标记；每到一帧结束（vs 下降沿）把标记
//   锁存成读基准，下一帧就从这个基准开始顺序读出 640 个点。
//
//   为什么要过零锁相：如果读基准固定（比如永远从物理地址 0 读），每一帧
//   取的是一段随机相位的波形，画面会左右乱跳。用触发点做基准后，波形在
//   屏幕上位置稳定，看起来才像示波器。
//
//   触发间隔至少 640 个样本（TRIG_GAP），确保一整屏 640 点都在同一次
//   触发之后被写入，画面里不会出现"半新半旧"的接缝。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效。
//
// 接口：
//   in  I_vs_fall      帧结束脉冲（单拍）
//   in  I_samp_valid   48kHz 样本有效（单拍，来自 I2S_receiver）
//   in  I_samp[23:0]   有符号 24bit PCM，取高 8bit 存入 RAM
//   in  I_rd_x[9:0]    读地址（像素列坐标 0..639）
//   out O_rd_data[7:0] 读数据（1 拍延迟，与像素流水同拍到齐）
//
// 参数：无（宽度固定 640）
//
// 内部例化：无（1 片 640×8 的 RAM，综合成 1 个 BRAM9K 或分布式 RAM）
//
// 备注：
//   读地址 = (读基准 + 像素列) mod 640，用一次加法 + 一次条件减法实现，
//   保证所有读地址都落在真正写过的 0..639 区间内（否则未写单元会读出 x）。
//=============================================================================
`timescale 1ns / 1ps

module wave_capture (
    input  wire               I_clk,
    input  wire               I_rst,
    input  wire               I_vs_fall,
    input  wire               I_samp_valid,
    input  wire signed [23:0] I_samp,
    input  wire [9:0]         I_rd_x,
    output reg  [7:0]         O_rd_data
);

    localparam [9:0] W        = 10'd640;
    localparam [9:0] TRIG_GAP = 10'd640;   // 两次触发的最小间隔
    localparam [9:0] GAP_MAX  = 10'd1023;  // 间隔计数器饱和值

    reg  [7:0] mem [0:639];

    reg  [9:0] wr_x;        // 写指针（循环）
    reg        neg_d;       // 上一个有效样本的符号（1 = 负）
    reg  [9:0] gap_cnt;     // 距上次触发的样本数（饱和计数）
    reg  [9:0] trig_base;   // 最近一次的触发地址
    reg  [9:0] rd_base;     // 本帧使用的读基准（vs 边界更新）

    wire samp_neg = I_samp[23];
    wire zc       = neg_d & ~samp_neg;                  // 负 → 正 过零
    wire trig_ok  = zc && (gap_cnt >= TRIG_GAP);

    //-------------------------------------------------------------------------
    // 写侧：连续采样 + 过零触发
    //-------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            wr_x      <= 10'd0;
            neg_d     <= 1'b0;
            gap_cnt   <= 10'd0;
            trig_base <= 10'd0;
        end
        else if (I_samp_valid) begin
            mem[wr_x] <= I_samp[23:16];                 // 24bit → 高 8bit
            wr_x      <= (wr_x == W - 10'd1) ? 10'd0 : wr_x + 10'd1;

            neg_d <= samp_neg;

            if (trig_ok) begin
                trig_base <= wr_x;
                gap_cnt   <= 10'd0;
            end
            else if (gap_cnt != GAP_MAX) begin
                gap_cnt <= gap_cnt + 10'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 帧边界锁存读基准（独立于采样节拍，保证 vs 脉冲一次不丢）
    //-------------------------------------------------------------------------
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)            rd_base <= 10'd0;
        else if (I_vs_fall)   rd_base <= trig_base;
    end

    //-------------------------------------------------------------------------
    // 读侧：(rd_base + x) mod 640，输出打一拍
    //   I_rd_x 在消隐期可以大于 639，这里做一次减 640 后仍然越界就取 0，
    //   保证 mem 的读地址永远落在 0..639，不会越界访问。
    //-------------------------------------------------------------------------
    wire [10:0] rsum  = {1'b0, rd_base} + {1'b0, I_rd_x};
    wire [10:0] rmod  = (rsum >= {1'b0, W}) ? (rsum - {1'b0, W}) : rsum;
    wire        r_ok  = (rmod < {1'b0, W});
    wire [9:0]  raddr = r_ok ? rmod[9:0] : 10'd0;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) O_rd_data <= 8'd0;
        else       O_rd_data <= mem[raddr];
    end

endmodule
