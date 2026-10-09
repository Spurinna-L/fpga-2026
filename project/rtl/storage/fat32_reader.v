//=============================================================================
// fat32_reader.v  —  FAT32 只读文件系统（自研，全硬件状态机）
//-----------------------------------------------------------------------------
// 【第 2 周主工作量，也是最大进度风险】采用"先易后难"策略：
//   阶段 1：仅支持 8.3 短文件名 + 根目录（无子目录、无 LFN）——保证按期可用；
//   阶段 2：扩展长文件名 / 子目录 / 多目录项。
//
// 解析流程（每步一个状态机，按扇区从 sd_ctrl 取数）：
//   MBR(0 扇区) → 分区表 → BPB(FAT32 引导扇区)
//     → 读取 FAT 表项字段：BPB_RootClus / FATSz / RsvdSecCnt / SecPerClus ...
//     → 根目录簇链（cluster chain via FAT）逐项扫描目录项
//     → 命中文件：按首簇 + FAT 链拼接出连续/非连续数据流
//   FAT32 目录项 32B：name[0..10] + attr + first_cluster(高/低) + size
//
// 对外提供两类接口：
//   1) 目录扫描：把命中文件的 {name, first_cluster, size} 交给 media_scan；
//   2) 文件读：按"扇区 LBA"顺序输出，供 bmp_decoder / wav_player 消费。
//
// 【当前状态】接口骨架。阶段 1 实现在第 2 周落地（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module fat32_reader (
    input  wire        clk,          // 系统 50MHz
    input  wire        rst_n,

    // ---- 连接 sd_ctrl（扇区读） ----
    output reg  [31:0] sd_sec,
    output reg         sd_req,
    input  wire [7:0]  sd_data,
    input  wire        sd_valid,
    input  wire        sd_done,
    output wire        sd_pop,

    // ---- 文件流输出（供解码器） ----
    output reg  [7:0]  file_data,
    output reg         file_valid,
    output reg         eof,
    input  wire        file_pop,

    // ---- 控制 ----
    input  wire        start,        // 启动一次文件读
    input  wire [31:0] file_cluster, // 文件首簇（来自目录项）
    output reg         busy,
    output reg         done
);

    // TODO(第 2 周):
    //   1) 上电后顺序读 0 扇区解析 MBR，再读分区起始扇区解析 BPB；
    //   2) 从 BPB 提取 RootClus、FAT 起始扇区、SecPerClus；
    //   3) 用 FAT 链把 file_cluster 展开为扇区序列，向 sd_ctrl 逐扇区请求；
    //   4) 把 sd_data 流按字节转发到 file_data（经异步 FIFO 已在 sd_ctrl 内完成 CDC）；
    //   5) 遇到文件 size 边界置 eof。

    // 占位：空闲，不驱动总线，避免误触发
    assign sd_pop = 1'b0;

    always @(posedge clk or negedge rst_n) begin        if (!rst_n) begin
            sd_sec     <= 32'd0;
            sd_req     <= 1'b0;
            file_data  <= 8'd0;
            file_valid <= 1'b0;
            eof        <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
        end else begin
            sd_req     <= 1'b0;
            file_valid <= 1'b0;
            done       <= 1'b0;
            busy       <= 1'b0;
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, sd_data, sd_valid, sd_done, sd_pop, start, file_cluster,
                     file_pop};
    // synthesis translate_on

endmodule
