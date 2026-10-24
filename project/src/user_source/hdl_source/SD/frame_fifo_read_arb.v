//=============================================================================
// frame_fifo_read_arb.v — 双读帧缓存的单路读通道（带突发仲裁握手）
//-----------------------------------------------------------------------------
// 功能：
//   由官方 frame_fifo_read 扩展而来：
//     1) 读基地址由 4 选 1 简化为单一 read_base_addr；
//     2) 新增 burst_req / burst_grant / burst_done 三个握手，供 rd_arbiter 仲裁；
//     3) S_CHECK_FIFO 只有 burst_grant=1 时才允许发起下一次突发；
//     4) 用 rx_valid 统计“实际收回的字数”判断突发结束（不依赖固定读延迟）。
//   其余状态机、地址递增、FIFO 清空、read_finish 语义与官方版本一致。
//
// 时钟/复位：mem_clk = 125MHz；rst 高有效。
//
// 接口：
//   read_req / read_req_ack / read_finish、read_base_addr / read_len
//   wrusedw[9:0]、fifo_aclr、App_rd_en / App_rd_addr[20:0]、O_rd_busy
//   burst_req / burst_grant / burst_done（接 rd_arbiter）
//   rx_valid（本通道实际收到读数据有效）
//
// 参数：
//   ADDR_BITS=21、BURST_BITS=9、FIFO_DEPTH=512、BURST_SIZE=256
//
// 常量：
//   S_IDLE / S_ACK / S_CHECK_FIFO / S_READ_BURST / S_READ_BURST_END / S_END
//
// 内部例化：无
//
// 状态：⚠ 仅被未启用的 frame_read_write_dual 例化，M2 重构用。
//=============================================================================
`timescale 1ns/1ps

module frame_fifo_read_arb
#
(
    parameter MEM_DATA_BITS          = 32,
    parameter ADDR_BITS              = 21,
    parameter BURST_BITS             = 9,
    parameter FIFO_DEPTH             = 512,
    parameter BURST_SIZE             = 256
)
(
    input                            rst,
    input                            mem_clk,
    input                            Sdr_init_done,
    input                            Sdr_init_ref_vld,
    input                            Sdr_busy,

    input                            App_wr_busy,
    output                           O_rd_busy,

    // 仲裁握手
    output                           burst_req,
    input                            burst_grant,
    output                           burst_done,

    output                           App_rd_en,
    output [ADDR_BITS - 1:0]         App_rd_addr,

    input                            read_req,        // level, held until ack
    output reg                       read_req_ack,
    output                           read_finish,

    input  [ADDR_BITS - 1:0]         read_base_addr,
    input  [ADDR_BITS - 1:0]         read_len,

    output reg                       fifo_aclr,
    input  [9:0]                     wrusedw,

    // 本通道实际收到的读数据有效脉冲（用于按“收回字数”判断突发结束，
    // 不依赖固定的 SDRAM 读延迟）
    input                            rx_valid
);

localparam ZERO = 256'd0;

localparam S_IDLE                    = 0;
localparam S_ACK                     = 1;
localparam S_CHECK_FIFO              = 2;
localparam S_READ_BURST              = 3;
localparam S_READ_BURST_END          = 4;
localparam S_END                     = 5;

reg                                  read_req_d0;
reg                                  read_req_d1;
reg                                  read_req_d2;
reg [ADDR_BITS - 1:0]                read_len_d0;
reg [ADDR_BITS - 1:0]                read_len_d1;
reg [ADDR_BITS - 1:0]                read_len_latch;
reg [ADDR_BITS - 1:0]                read_cnt;
reg [3:0]                            state;
reg [ADDR_BITS - 1:0]                App_rd_addr_r;

reg [BURST_BITS - 1:0]               burst_cnt;
reg                                  App_rd_en_r;
reg                                  App_rd_en_d0;

// 与 M0 原始 frame_fifo_read 完全一致的突发完成逻辑：
// 发完 256 个读命令后等待 10 拍，认为 SDRAM 数据已全部返回。
// （上板对比已证明 M0 引擎干净；rx_cnt 方案在真实控制器上会破坏像素流）
reg [3:0] rd_delay;
wire rd_burst_finish;

wire fifo_ready = (wrusedw < (FIFO_DEPTH - BURST_SIZE)) && ~App_wr_busy;
wire burst_issued = (burst_cnt >= BURST_SIZE);

assign App_rd_addr  = App_rd_addr_r;
assign O_rd_busy    = (state == S_READ_BURST);
assign rd_burst_finish = (state == S_READ_BURST) && burst_issued && (rd_delay == 4'd10);
assign burst_done   = rd_burst_finish;
assign read_finish  = (state == S_END);
assign App_rd_en    = App_rd_en_d0;

// 只有在 CHECK_FIFO 且 FIFO 需要补充时才请求总线
assign burst_req    = (state == S_CHECK_FIFO) && fifo_ready && ~read_req_d2;

always @(posedge mem_clk or posedge rst)
begin
    if (rst == 1'b1)
    begin
        read_req_d0    <= 1'b0;
        read_req_d1    <= 1'b0;
        read_req_d2    <= 1'b0;
        read_len_d0    <= ZERO[ADDR_BITS - 1:0];
        read_len_d1    <= ZERO[ADDR_BITS - 1:0];
    end
    else
    begin
        read_req_d0    <= read_req;
        read_req_d1    <= read_req_d0;
        read_req_d2    <= read_req_d1;
        read_len_d0    <= read_len;
        read_len_d1    <= read_len_d0;
    end
end

// 与 M0 一致：最后一个读命令后数 10 拍
always @(posedge mem_clk or posedge rst)
begin
    if (rst || App_rd_en)
        rd_delay <= 4'd0;
    else if (rd_delay < 4'd10)
        rd_delay <= rd_delay + 1'b1;
end

always @(posedge mem_clk or posedge rst)
begin
    if (rst == 1'b1)
    begin
        burst_cnt     <= ZERO[BURST_BITS - 1:0];
        App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
        App_rd_en_d0  <= 1'b0;
    end
    else begin
        if (state == S_CHECK_FIFO)
            burst_cnt <= ZERO[BURST_BITS - 1:0];
        else if (App_rd_en)
            burst_cnt <= burst_cnt + 1'b1;

        if (state == S_ACK)
            App_rd_addr_r <= read_base_addr;
        else if (App_rd_en)
            App_rd_addr_r <= App_rd_addr_r + 1'b1;

        if (App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
            App_rd_en_d0 <= 1'b1;
        else
            App_rd_en_d0 <= 1'b0;
    end
end

always @(posedge mem_clk or posedge rst)
begin
    if (rst == 1'b1)
    begin
        state          <= S_IDLE;
        read_len_latch <= ZERO[ADDR_BITS - 1:0];
        App_rd_en_r    <= 1'b0;
        read_cnt       <= ZERO[ADDR_BITS - 1:0];
        fifo_aclr      <= 1'b0;
        read_req_ack   <= 1'b0;
    end
    else
        case (state)
            S_IDLE:
            begin
                if (read_req_d2 == 1'b1 && Sdr_init_done)
                    state <= S_ACK;
                read_req_ack <= 1'b0;
            end
            S_ACK:
            begin
                if (read_req_d2 == 1'b0)
                begin
                    state        <= S_CHECK_FIFO;
                    fifo_aclr    <= 1'b0;
                    read_req_ack <= 1'b0;
                end
                else
                begin
                    read_req_ack   <= 1'b1;
                    fifo_aclr      <= 1'b1;
                    read_len_latch <= read_len_d1;
                end
                read_cnt <= ZERO[ADDR_BITS - 1:0];
            end
            S_CHECK_FIFO:
            begin
                if (read_req_d2 == 1'b1)
                begin
                    state <= S_ACK;
                end
                else if (fifo_ready && burst_grant)
                begin
                    state      <= S_READ_BURST;
                    App_rd_en_r <= 1'b1;
                end
            end
            S_READ_BURST:
            begin
                if (burst_done == 1'b1)
                begin
                    App_rd_en_r <= 1'b0;
                    state       <= S_READ_BURST_END;
                    read_cnt    <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
                end
            end
            S_READ_BURST_END:
            begin
                if (read_req_d2 == 1'b1)
                    state <= S_ACK;
                else if (read_cnt < read_len_latch)
                    state <= S_CHECK_FIFO;
                else
                    state <= S_END;
            end
            S_END:
                state <= S_IDLE;
            default:
                state <= S_IDLE;
        endcase
end

endmodule
