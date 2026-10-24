`timescale 1ns/1ps
//=============================================================================
// sdram_selftest.v — SDRAM 读写自检（K14 触发，结果送数码管/LED）
//-----------------------------------------------------------------------------
// 功能：
//   在指定帧缓冲区内依次做三件事，用来回答“那个地址到底存进去没有”：
//     1) 停机等待（SETTLE_CYCLES）：让总线上残留的读写命令排空；
//     2) 写：i = 0..TEST_WORDS-1，addr = base + i，din = pat(i)（每个地址唯一）；
//     3) 读：连续发 TEST_WORDS 个读命令，按返回顺序逐字比对 pat(i)。
//   记录首个错误地址（及对应的 y/x）和错误总数；完成后把总线还给帧缓存。
//
// 为什么这样测：
//   - 图案与地址一一对应，任何“写丢失/写错址/读错址”都会表现为某个 i 不匹配；
//   - 读返回顺序与发出顺序一致，用返回计数 rd_got 反推地址，不依赖固定延迟；
//   - 测的是**当前显示的那块缓冲**（base 由顶层按 disp_buf_mem 选择），
//     所以自检报出的 y 可以直接和屏幕上的条纹高度对照。
//
// 时钟/复位：clk = ext_mem_clk 125MHz；rst 高有效（rst_mem）。
//
// 接口：
//   in  start_req      50MHz 域翻转电平，内部 3FF + 边沿检测（一次翻转 = 一次测试）
//   in  Sdr_init_done  SDRAM 初始化完成，未完成不启动
//   in  Sdr_rd_en/Sdr_rd_dout   SDRAM 读返回
//   in  I_base         本次要测的缓冲区基地址（启动时锁存）
//   out O_active       测试占用总线（顶层用它切换 mux 并复位帧缓存引擎）
//   out O_done         至少完成过一次测试
//   out O_timeout      读阶段超时（结果为无效）
//   out O_bad_cnt      错误字数（24bit）
//   out O_first_addr   首个错误地址（绝对值）
//   out O_first_y/x    首个错误对应的行/列（按 640 宽换算）
//   out O_wr_en/addr/din 、O_rd_en/addr   SDRAM 用户接口
//
// 参数：
//   TEST_WORDS     = 307200   一帧字数
//   SETTLE_CYCLES  = 1024     启动前排空
//   DRAIN_CYCLES   = 256      写后/读后等待
//   TIMEOUT_CYCLES = 2*TEST_WORDS+4096   读阶段超时
//
// 内部例化：无
//
// 备注：
//   - 测试会覆盖所测缓冲区的内容，测完需按 K1 重新加载图片；
//   - 测试期间屏幕会短暂花屏（读 FIFO 断粮），属正常现象；
//   - 写阶段按 1 字/拍 满速写，比正常路径更严苛（正常是 256 字/突发）。
//=============================================================================
module sdram_selftest #(
    parameter [20:0] TEST_WORDS     = 21'd307_200,
    parameter integer SETTLE_CYCLES = 1024,
    parameter integer DRAIN_CYCLES  = 256
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start_req,
    input  wire        Sdr_init_done,
    input  wire        Sdr_rd_en,
    input  wire [31:0] Sdr_rd_dout,
    input  wire [20:0] I_base,

    output reg         O_active,
    output reg         O_done,
    output reg         O_timeout,
    output reg  [23:0] O_bad_cnt,
    output reg  [20:0] O_first_addr,
    output reg  [8:0]  O_first_y,
    output reg  [9:0]  O_first_x,

    output wire        O_wr_en,
    output wire [20:0] O_wr_addr,
    output wire [31:0] O_wr_din,
    output wire        O_rd_en,
    output wire [20:0] O_rd_addr
);

    localparam [2:0] S_IDLE     = 3'd0,
                     S_SETTLE   = 3'd1,
                     S_WRITE    = 3'd2,
                     S_WR_DRAIN = 3'd3,
                     S_READ     = 3'd4,
                     S_RD_DRAIN = 3'd5;

    localparam integer TIMEOUT_CYCLES = 2*TEST_WORDS + 4096;

    // 地址 -> 唯一图案（低位随地址翻转，便于暴露 DQ 位错）
    function [31:0] pat;
        input [20:0] i;
        begin
            pat = {i[18:0], 13'h1A5};
        end
    endfunction

    reg [2:0]  state;
    reg [2:0]  start_sync;
    wire       start_pulse = start_sync[2] ^ start_sync[1];

    reg [20:0] base_r;
    reg [20:0] wr_idx;
    reg [20:0] rd_issue;
    reg [20:0] rd_got;
    reg [9:0]  exp_x;
    reg [8:0]  exp_y;
    reg [23:0] settle_cnt;
    reg [23:0] drain_cnt;
    reg [23:0] timeout;

    wire do_clr = (state == S_IDLE) && start_pulse && Sdr_init_done;

    // SDRAM 读数据先在 125MHz 域打一拍，切断
    // “硬核 diq -> 32bit 比较 -> O_first_y 使能” 的长路径
    reg [31:0] rd_dout_q;
    reg        rd_vld_q;

    assign O_wr_en   = (state == S_WRITE);
    assign O_wr_addr = base_r + wr_idx;
    assign O_wr_din  = pat(wr_idx);
    assign O_rd_en   = (state == S_READ) && (rd_issue < TEST_WORDS);
    assign O_rd_addr = base_r + rd_issue;

    //-------------------------------------------------------------------------
    // 启动请求：50MHz 域翻转电平 -> 3FF -> 边沿检测
    //-------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            start_sync <= 3'b000;
        else
            start_sync <= {start_sync[1:0], start_req};
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_dout_q <= 32'd0;
            rd_vld_q  <= 1'b0;
        end else begin
            rd_dout_q <= Sdr_rd_dout;
            rd_vld_q  <= (state == S_READ) && Sdr_rd_en;
        end
    end

    //-------------------------------------------------------------------------
    // 读回比对：返回一个比一个，按 rd_got 反推地址
    //-------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst || do_clr) begin
            rd_got       <= 21'd0;
            exp_x        <= 10'd0;
            exp_y        <= 9'd0;
            O_bad_cnt    <= 24'd0;
            O_first_addr <= 21'd0;
            O_first_y    <= 9'd0;
            O_first_x    <= 10'd0;
        end else if ((state == S_READ) && rd_vld_q && (rd_got < TEST_WORDS)) begin
            if (rd_dout_q != pat(rd_got)) begin
                if (O_bad_cnt == 24'd0) begin
                    O_first_addr <= base_r + rd_got;
                    O_first_y    <= exp_y;
                    O_first_x    <= exp_x;
                end
                O_bad_cnt <= O_bad_cnt + 24'd1;
            end

            rd_got <= rd_got + 21'd1;
            if (exp_x == 10'd639) begin
                exp_x <= 10'd0;
                exp_y <= exp_y + 9'd1;
            end else begin
                exp_x <= exp_x + 10'd1;
            end
        end else if (state != S_READ) begin
            rd_got <= 21'd0;
            exp_x  <= 10'd0;
            exp_y  <= 9'd0;
        end
    end

    //-------------------------------------------------------------------------
    // 主状态机
    //-------------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            O_active   <= 1'b0;
            O_done     <= 1'b0;
            O_timeout  <= 1'b0;
            base_r     <= 21'd0;
            wr_idx     <= 21'd0;
            rd_issue   <= 21'd0;
            settle_cnt <= 24'd0;
            drain_cnt  <= 24'd0;
            timeout    <= 24'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start_pulse && Sdr_init_done) begin
                        O_active   <= 1'b1;
                        O_done     <= 1'b0;
                        O_timeout  <= 1'b0;
                        base_r     <= I_base;
                        wr_idx     <= 21'd0;
                        rd_issue   <= 21'd0;
                        settle_cnt <= 24'd0;
                        drain_cnt  <= 24'd0;
                        timeout    <= 24'd0;
                        state      <= S_SETTLE;
                    end
                end

                S_SETTLE: begin
                    if (settle_cnt == SETTLE_CYCLES-1) begin
                        wr_idx <= 21'd0;
                        state  <= S_WRITE;
                    end else begin
                        settle_cnt <= settle_cnt + 24'd1;
                    end
                end

                S_WRITE: begin
                    // 满速写：最后一拍仍然拉高 O_wr_en
                    if (wr_idx == TEST_WORDS-1) begin
                        drain_cnt <= 24'd0;
                        state     <= S_WR_DRAIN;
                    end else begin
                        wr_idx <= wr_idx + 21'd1;
                    end
                end

                S_WR_DRAIN: begin
                    if (drain_cnt == DRAIN_CYCLES-1) begin
                        rd_issue <= 21'd0;
                        timeout  <= 24'd0;
                        state    <= S_READ;
                    end else begin
                        drain_cnt <= drain_cnt + 24'd1;
                    end
                end

                S_READ: begin
                    if (rd_issue < TEST_WORDS)
                        rd_issue <= rd_issue + 21'd1;

                    if (rd_got >= TEST_WORDS) begin
                        drain_cnt <= 24'd0;
                        state     <= S_RD_DRAIN;
                    end else if (timeout == TIMEOUT_CYCLES-1) begin
                        O_timeout <= 1'b1;
                        drain_cnt <= 24'd0;
                        state     <= S_RD_DRAIN;
                    end else begin
                        timeout <= timeout + 24'd1;
                    end
                end

                S_RD_DRAIN: begin
                    if (drain_cnt == DRAIN_CYCLES-1) begin
                        O_active <= 1'b0;
                        O_done   <= 1'b1;
                        state    <= S_IDLE;
                    end else begin
                        drain_cnt <= drain_cnt + 24'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
