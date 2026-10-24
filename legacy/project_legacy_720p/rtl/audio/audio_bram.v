//=============================================================================
// audio_bram.v  —  音频采样双口 BRAM（一边写、一边读）
//-----------------------------------------------------------------------------
//  【它是什么】
//    FPGA 片内有一块块专用存储器叫 BRAM(Block RAM)。它像一个「整数数组」：
//      mem[0], mem[1], mem[2] ... 每个格子存 16bit（= 1 个音频采样）。
//    本模块把这块 BRAM 包成一个「简单双口 RAM」：
//      * 写口(wr_*)：给 wr_en=1 且 wr_addr/wr_data，就在时钟上升沿写进去。
//      * 读口(rd_*)：给 rd_addr，下一个时钟上升沿 rd_data 上就是该地址的数据。
//    两个口可以各用各的时钟；本工程二者都是 50MHz，所以接同一个 clk 即可。
//
//  【为什么读要晚一拍？】
//    这是"同步读"BRAM 的特性：地址打进去的当拍，数据还没出来；要等下一个
//    时钟沿才出现在 rd_data。播放器正是利用"地址保持很多拍"来避开这一拍延迟
//    （播放节拍只有 48kHz，地址几万拍才换一次，早就有数据了）。
//
//  【深度怎么算？】
//    DEPTH = 2^AW 个采样。AW=15 → 32768 个采样 ≈ 0.68 秒 @48kHz。
//    32768×16bit = 512Kbit，约占 EG4S20 BRAM 的一小半，安全。
//    想存更长音频就把 AW 调大（16→1.37 秒，17→2.7 秒…，注意别超过芯片容量）。
//
//  【谁来写、谁来读】
//    写：wav_to_pcm 的 bram_we/addr/data（把解析出的 PCM 灌进来，写指针回卷）
//    读：r2r_dac_player 的 bram_addr/rd_data（按 48kHz 从环形缓冲取出）
//  【流式播放】本 BRAM 被当作"环形缓冲(ring buffer)"使用：写、读指针各自独立回卷，
//    不再"先灌满再读"。溢写/读空的保护在 wav_r2r_top 与 r2r_dac_player 里做。
//=============================================================================
`timescale 1ns / 1ps

module audio_bram #(
    parameter integer AW    = 15,          // 地址位宽
    parameter integer DEPTH = (1 << AW)    // 深度（采样个数）
)(
    // ---------- 写口（来自 wav_to_pcm）----------
    input  wire          wr_clk,           // 写时钟
    input  wire          wr_en,            // 写使能
    input  wire [AW-1:0] wr_addr,          // 写地址
    input  wire [15:0]   wr_data,          // 写数据（16bit PCM）

    // ---------- 读口（给 r2r_dac_player）----------
    input  wire          rd_clk,           // 读时钟
    input  wire          rd_en,            // 读使能（一般恒为 1）
    input  wire [AW-1:0] rd_addr,          // 读地址
    output reg  [15:0]   rd_data           // 读数据（同步读，晚 1 拍）
);

    // 存储器本体：DEPTH 个 16bit 格子。
    // 综合工具会自动把这种"寄存器数组 + 同步读写"识别成片内 BRAM。
    reg [15:0] mem [0:DEPTH-1];

    // ---------------- 写口 ----------------
    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // ---------------- 读口（同步读，晚 1 拍出数据）----------------
    always @(posedge rd_clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

    // 说明：
    //  * 这里没有做"读写同一地址"的冲突保护。安全性由上位模块保证：
    //    wav_to_pcm 的写指针不会追过读指针——供过于求时由 bp_pause 背压上游；
    //    播放器在读空(fill==0)时不会取数，因此不会读到即将被覆盖的旧数据。
    //  * 上电时 BRAM 内容不确定，但播放器要等缓冲攒够领先量才开始，且断音时
    //    保持静音/上一采样，因此不会把未初始化的噪声送出去。

endmodule
