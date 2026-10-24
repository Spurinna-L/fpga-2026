//=============================================================================
// rd_arbiter.v — 125MHz SDRAM 读突发仲裁器（1 写 2 读中的 2 读）
//-----------------------------------------------------------------------------
// 功能：
//   在两个读通道之间按“整次突发”分配 SDRAM 读总线，而不是逐拍切换：
//     1) 通道 FIFO 水位低时拉高 burst_req；
//     2) 仲裁器锁定 grant（0=A / 1=B），水位更低者优先，相同则 round-robin；
//     3) 通道看到 grant_valid 后启动一次突发，busy=1；
//     4) busy 落下后本次授权用掉，locked 保持到 DRAIN_CYCLES 排空后释放。
//   grant 在锁定期保持（sticky），保证晚到的 Sdr_rd_en 仍被路由到正确 FIFO。
//
// 时钟/复位：clk = mem_clk 125MHz；rst 高有效。
//
// 接口：
//   in  req_a / req_b          通道请求
//   in  busy_a / busy_b        通道正处于突发中（O_rd_busy）
//   in  level_a / level_b[9:0] 通道 FIFO 水位
//   out grant                  0=A / 1=B（sticky，用于数据路由）
//   out locked                 总线已分配
//   out grant_valid            允许启动一次新的突发
//
// 参数：
//   DRAIN_CYCLES = 8   突发结束后的排空等待拍数
//
// 内部例化：无
//
// 状态：⚠ 仅被未启用的 frame_read_write_dual 例化，M2 重构用。
//=============================================================================
`timescale 1ns/1ps

module rd_arbiter #(
    parameter integer DRAIN_CYCLES = 8
)(
    input  wire clk,
    input  wire rst,
    input  wire req_a,
    input  wire req_b,
    input  wire busy_a,          // 通道 A 正处于突发中（O_rd_busy）
    input  wire busy_b,          // 通道 B 正处于突发中（O_rd_busy）
    input  wire [9:0] level_a,   // 通道 A 读 FIFO 水位（越小越紧急）
    input  wire [9:0] level_b,   // 通道 B 读 FIFO 水位
    output reg  grant,           // 0=A, 1=B（sticky，用于数据路由）
    output reg  locked,          // 总线已分配
    output wire grant_valid      // 允许启动一次新的突发
);

    reg       rr;                // round-robin 指针
    reg       started;           // 本次授权内已经观察到一个突发
    reg       done_seen;         // 突发已结束，等排空
    reg [3:0] idle_cnt;

    wire busy_now = (grant == 1'b0) ? busy_a : busy_b;

    // 授权窗口内、且本次突发尚未结束时，才允许启动
    assign grant_valid = locked && !done_seen;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            grant     <= 1'b0;
            locked    <= 1'b0;
            rr        <= 1'b0;
            started   <= 1'b0;
            done_seen <= 1'b0;
            idle_cnt  <= 4'd0;
        end else if (!locked) begin
            started   <= 1'b0;
            done_seen <= 1'b0;
            idle_cnt  <= 4'd0;

            if (req_a && req_b) begin
                // 谁更空先喂谁；水位相同再 round-robin
                if (level_a < level_b) begin
                    grant  <= 1'b0;
                    rr     <= 1'b1;
                end else if (level_b < level_a) begin
                    grant  <= 1'b1;
                    rr     <= 1'b0;
                end else begin
                    grant  <= rr;
                    rr     <= ~rr;
                end
                locked <= 1'b1;
            end else if (req_a) begin
                grant  <= 1'b0;
                rr     <= 1'b1;
                locked <= 1'b1;
            end else if (req_b) begin
                grant  <= 1'b1;
                rr     <= 1'b0;
                locked <= 1'b1;
            end
        end else begin
            if (busy_now) begin
                started  <= 1'b1;
                idle_cnt <= 4'd0;
            end else if (started && !done_seen) begin
                // 突发刚结束，进入排空窗口
                done_seen <= 1'b1;
                idle_cnt  <= 4'd0;
            end else if (idle_cnt >= (DRAIN_CYCLES - 1)) begin
                locked    <= 1'b0;
                started   <= 1'b0;
                done_seen <= 1'b0;
                idle_cnt  <= 4'd0;
            end else begin
                idle_cnt <= idle_cnt + 4'd1;
            end
        end
    end

endmodule
