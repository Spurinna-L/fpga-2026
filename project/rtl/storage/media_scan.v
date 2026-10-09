//=============================================================================
// media_scan.v  —  媒体资源扫描 / 索引表
//-----------------------------------------------------------------------------
// 上电后扫描 SD 卡根目录，识别 *.BMP（图片）与 *.WAV（音频），建立"媒体索引表"
// （媒体类型 / 首簇 / 文件大小 / 序号），供 main_fsm 轮播调度与数码管显示序号。
//
// 依赖 fat32_reader 逐个目录项的输出；本模块只做文件名后缀匹配与表项写入。
// 索引表建议存放于 ERAM（小容量）或 SDRAM 的"媒体索引"区（见存储映射）。
//
// 【当前状态】接口骨架；后缀匹配与表写入在第 2 周实现（见 TODO）。
//=============================================================================
`timescale 1ns / 1ps

module media_scan (
    input  wire        clk,
    input  wire        rst_n,

    // 扫描控制
    input  wire        scan_start,
    output reg         scanning,
    output reg         done,

    // 目录项字节流（来自 fat32_reader）
    output wire        dir_pop,
    input  wire        dir_valid,
    input  wire [7:0]  dir_data,

    // 媒体索引表写入（→ ERAM / SDRAM）
    output reg         idx_we,
    output reg  [7:0]  idx_addr,
    output reg  [1:0]  idx_type,    // 0=BMP, 1=WAV, 2=其他
    output reg  [31:0] idx_cluster,
    output reg  [31:0] idx_size,
    output reg  [7:0]  media_count  // 有效媒体数量
);

    // TODO(第 2 周):
    //   1) 用 32B 目录项状态机缓存 name[8.3] 与 attr；
    //   2) 匹配扩展名 "BMP"/"WAV"（大小写不敏感）；
    //   3) 命中则 idx_we 写表：idx_addr 递增，记录 type/cluster/size；
    //   4) 扫描结束置 done，并更新 media_count。

    assign dir_pop = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scanning    <= 1'b0;
            done        <= 1'b0;
            idx_we      <= 1'b0;
            idx_addr    <= 8'd0;
            idx_type    <= 2'd0;
            idx_cluster <= 32'd0;
            idx_size    <= 32'd0;
            media_count <= 8'd0;
        end else begin
            idx_we   <= 1'b0;
            scanning <= scan_start;
            done     <= 1'b0;
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, dir_valid, dir_data};
    // synthesis translate_on

endmodule
