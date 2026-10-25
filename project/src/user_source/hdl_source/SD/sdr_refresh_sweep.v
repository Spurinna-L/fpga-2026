`timescale 1ns/1ps
//=============================================================================
// sdr_refresh_sweep.v — 消隐期“顺序整段读”后台扫描（保持闲置图片槽）
//-----------------------------------------------------------------------------
// 背景：
//   实测：正在显示的槽永远干净（每帧被顺序读满 307200 字），而闲置槽放几分钟
//   后会出现稀疏、固定位置的噪点（数据丢失）；把地址按 128 字步长“点读”一遍
//   完全无效。说明这颗硬核只把“顺序整段读”当作有效访问/刷新。
//
// 做法：
//   在每帧读完后（read_finish）到下一个 vs 之前，顺序读 4 个槽所在的连续
//   地址空间（0 .. 1,228,799），每帧读约 150k 字（1.2ms）：
//       addr = scan_addr, scan_addr+1, ...（跨帧连续，不重置）
//   走完 1,228,800 字后回绕到 0。整个空间约 8 帧（≈137ms）读完一遍，
//   等价于“每个槽每隔 137ms 被顺序读一遍”。
//
// 安全性：
//   - 只在 read_finish 之后、vs 之前工作，此时帧读 FSM 处于 IDLE；
//   - 扫描期间的读数据对帧缓存屏蔽（不写 rfifo）；
//   - 每帧最多 150k 拍，留出余量给最后一个读数据返回和 vs 前的排空。
//
// 接口：
//   start   帧读完成脉冲（ext_mem_clk 域，单拍）
//   stop    下一帧 read_req（已同步到 ext_mem_clk），高电平立即停止
//   active  正在扫描（顶层用它切换 App_rd_en/addr 并屏蔽 rfifo 写）
//   en/addr SDRAM 读命令
//=============================================================================
module sdr_refresh_sweep (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        stop,
    output reg         active,
    output reg         en,
    output reg  [20:0] addr
);

    // 只扫描实际使用的 4 个槽：4 × 307200 = 1,228,800 字
    localparam [20:0] LAST_ADDR  = 21'd1_228_799;
    localparam [17:0] MAX_CYCLES = 18'd150_000;   // 每帧最多 1.2ms

    reg [20:0] scan_addr;   // 跨帧保持，顺序推进
    reg [17:0] dur;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active    <= 1'b0;
            en        <= 1'b0;
            addr      <= 21'd0;
            scan_addr <= 21'd0;
            dur       <= 18'd0;
        end else if (start) begin
            active    <= 1'b1;
            en        <= 1'b1;
            addr      <= scan_addr;
            dur       <= 18'd0;
            scan_addr <= (scan_addr == LAST_ADDR) ? 21'd0 : (scan_addr + 21'd1);
        end else if (active) begin
            if (stop || (dur == MAX_CYCLES)) begin
                active <= 1'b0;
                en     <= 1'b0;
            end else begin
                addr      <= scan_addr;
                scan_addr <= (scan_addr == LAST_ADDR) ? 21'd0 : (scan_addr + 21'd1);
                dur       <= dur + 18'd1;
                en        <= 1'b1;
            end
        end else begin
            en <= 1'b0;
        end
    end

endmodule
