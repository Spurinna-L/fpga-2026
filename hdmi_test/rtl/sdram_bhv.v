//=============================================================================
// sdram_bhv.v  —  SDRAM 控制器"行为模型"（v2：贴近真控制器，仅仿真）
//-----------------------------------------------------------------------------
// v2 相比 v1 的关键改进（这些正是"模型跑通、上板却偏"的根源）：
//   1) 写侧【突发粒度】：只有写 FIFO 里攒够 WRx_LENGTH 个字，才成批写入，
//      每批地址前进 WRx_LENGTH —— 所以帧末会残留 <WRx_LENGTH 个字（漂移源）。
//   2) 读侧【突发预取】：读 FIFO 一旦少于 RDx_LENGTH 就成批预取 RDx_LENGTH 个字，
//      每批地址前进 RDx_LENGTH —— 所以读地址会"抢跑"，且帧末可能多预取一批。
//   3) 读侧【输出寄存器】：q 是 FIFO 头的寄存输出（与真器件的 softfifo 一致）。
//
// 其余契约与真 `Sdram_Control_4Port` 一致：WR/RD 各 2 口、xxx_LOAD 复位指针+清 FIFO、
// WRx_FULL / RDx_EMPTY 反压。
//
// 【红线】纯仿真模型，不可综合；上板用真 sdram_ctrl_wrap。
//=============================================================================
`timescale 1ns / 1ps

module sdram_bhv #(
    parameter ASIZE = 21,
    parameter DSIZE = 16,
    parameter FFA   = 10,          // FIFO 地址位宽（深度 1024，与真 softfifo 一致）
    parameter FF    = 1024
)(
    input  wire              CTRL_CLK,
    input  wire              SDRAM_CLK,
    input  wire              RESET_N,

    input  wire [DSIZE-1:0]  WR1_DATA,
    input  wire              WR1,
    input  wire [ASIZE-1:0]  WR1_ADDR,
    input  wire [ASIZE-1:0]  WR1_MAX_ADDR,
    input  wire [9:0]        WR1_LENGTH,
    input  wire              WR1_LOAD,
    input  wire              WR1_CLK,
    output wire              WR1_FULL,
    output wire [15:0]       WR1_USE,

    input  wire [DSIZE-1:0]  WR2_DATA,
    input  wire              WR2,
    input  wire [ASIZE-1:0]  WR2_ADDR,
    input  wire [ASIZE-1:0]  WR2_MAX_ADDR,
    input  wire [9:0]        WR2_LENGTH,
    input  wire              WR2_LOAD,
    input  wire              WR2_CLK,
    output wire              WR2_FULL,
    output wire [15:0]       WR2_USE,

    output wire [DSIZE-1:0]  RD1_DATA,
    input  wire              RD1,
    input  wire [ASIZE-1:0]  RD1_ADDR,
    input  wire [ASIZE-1:0]  RD1_MAX_ADDR,
    input  wire [9:0]        RD1_LENGTH,
    input  wire              RD1_LOAD,
    input  wire              RD1_CLK,
    output wire              RD1_EMPTY,
    output wire [15:0]       RD1_USE,

    output wire [DSIZE-1:0]  RD2_DATA,
    input  wire              RD2,
    input  wire [ASIZE-1:0]  RD2_ADDR,
    input  wire [ASIZE-1:0]  RD2_MAX_ADDR,
    input  wire [9:0]        RD2_LENGTH,
    input  wire              RD2_LOAD,
    input  wire              RD2_CLK,
    output wire              RD2_EMPTY,
    output wire [15:0]       RD2_USE
);

    localparam MEM_WORDS = (1 << ASIZE);
    reg [DSIZE-1:0] mem [0:MEM_WORDS-1];

    //=========================================================================
    // 宏：一个写端口（推入 + 突发排空）
    //=========================================================================
    // WR1
    reg [DSIZE-1:0] wf1 [0:FF-1];
    reg [FFA:0]     wf1_wp, wf1_rp;
    reg [ASIZE-1:0] wr1_ptr;
    reg [9:0]       wr1_cnt;
    reg             wr1_busy;

    assign WR1_FULL = ((wf1_wp - wf1_rp) >= (FF-1));
    assign WR1_USE  = wf1_wp - wf1_rp;

    always @(posedge WR1_CLK or negedge RESET_N) begin
        if (!RESET_N)      wf1_wp <= 0;
        else if (WR1_LOAD) wf1_wp <= 0;
        else if (WR1 && !WR1_FULL) begin
            wf1[wf1_wp[FFA-1:0]] <= WR1_DATA;
            wf1_wp <= wf1_wp + 1'b1;
        end
    end

    always @(posedge CTRL_CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            wf1_rp <= 0; wr1_ptr <= 0; wr1_cnt <= 0; wr1_busy <= 1'b0;
        end else if (WR1_LOAD) begin
            wf1_rp <= 0; wr1_ptr <= WR1_ADDR; wr1_cnt <= 0; wr1_busy <= 1'b0;
        end else if (!wr1_busy) begin
            if ((wf1_wp - wf1_rp) >= WR1_LENGTH) begin
                wr1_busy <= 1'b1; wr1_cnt <= WR1_LENGTH;   // 攒够一批，开始成批写
            end
        end else begin
            mem[wr1_ptr] <= wf1[wf1_rp[FFA-1:0]];
            wf1_rp  <= wf1_rp + 1'b1;
            wr1_ptr <= (wr1_ptr == WR1_MAX_ADDR - 1'b1) ? WR1_ADDR : wr1_ptr + 1'b1;
            wr1_cnt <= wr1_cnt - 1'b1;
            if (wr1_cnt == 10'd1) wr1_busy <= 1'b0;
        end
    end

    // WR2
    reg [DSIZE-1:0] wf2 [0:FF-1];
    reg [FFA:0]     wf2_wp, wf2_rp;
    reg [ASIZE-1:0] wr2_ptr;
    reg [9:0]       wr2_cnt;
    reg             wr2_busy;

    assign WR2_FULL = ((wf2_wp - wf2_rp) >= (FF-1));
    assign WR2_USE  = wf2_wp - wf2_rp;

    always @(posedge WR2_CLK or negedge RESET_N) begin
        if (!RESET_N)      wf2_wp <= 0;
        else if (WR2_LOAD) wf2_wp <= 0;
        else if (WR2 && !WR2_FULL) begin
            wf2[wf2_wp[FFA-1:0]] <= WR2_DATA;
            wf2_wp <= wf2_wp + 1'b1;
        end
    end

    always @(posedge CTRL_CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            wf2_rp <= 0; wr2_ptr <= 0; wr2_cnt <= 0; wr2_busy <= 1'b0;
        end else if (WR2_LOAD) begin
            wf2_rp <= 0; wr2_ptr <= WR2_ADDR; wr2_cnt <= 0; wr2_busy <= 1'b0;
        end else if (!wr2_busy) begin
            if ((wf2_wp - wf2_rp) >= WR2_LENGTH[9:0]) begin
                wr2_busy <= 1'b1; wr2_cnt <= WR2_LENGTH;
            end
        end else begin
            mem[wr2_ptr] <= wf2[wf2_rp[FFA-1:0]];
            wf2_rp  <= wf2_rp + 1'b1;
            wr2_ptr <= (wr2_ptr == WR2_MAX_ADDR - 1'b1) ? WR2_ADDR : wr2_ptr + 1'b1;
            wr2_cnt <= wr2_cnt - 1'b1;
            if (wr2_cnt == 10'd1) wr2_busy <= 1'b0;
        end
    end

    //=========================================================================
    // 一个读端口（突发预取 + 寄存输出）
    //=========================================================================
    // RD1
    reg [DSIZE-1:0] rf1 [0:FF-1];
    reg [FFA:0]     rf1_wp, rf1_rp;
    reg [ASIZE-1:0] rd1_ptr;
    reg [9:0]       rd1_cnt;
    reg             rd1_busy;
    reg [DSIZE-1:0] rd1_q;

    assign RD1_EMPTY = (rf1_wp == rf1_rp);
    assign RD1_USE   = rf1_wp - rf1_rp;
    assign RD1_DATA  = rd1_q;              // 寄存输出（show-ahead 的 q）

    always @(posedge CTRL_CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            rf1_wp <= 0; rd1_ptr <= 0; rd1_cnt <= 0; rd1_busy <= 1'b0;
        end else if (RD1_LOAD) begin
            rf1_wp <= 0; rd1_ptr <= RD1_ADDR; rd1_cnt <= 0; rd1_busy <= 1'b0;
        end else if (!rd1_busy) begin
            if ((rf1_wp - rf1_rp) < RD1_LENGTH) begin
                rd1_busy <= 1'b1; rd1_cnt <= RD1_LENGTH;   // 库存不足，成批预取
            end
        end else begin
            rf1[rf1_wp[FFA-1:0]] <= mem[rd1_ptr];
            rf1_wp  <= rf1_wp + 1'b1;
            rd1_ptr <= (rd1_ptr == RD1_MAX_ADDR - 1'b1) ? RD1_ADDR : rd1_ptr + 1'b1;
            rd1_cnt <= rd1_cnt - 1'b1;
            if (rd1_cnt == 10'd1) rd1_busy <= 1'b0;
        end
    end

    always @(posedge RD1_CLK or negedge RESET_N) begin
        if (!RESET_N)      rf1_rp <= 0;
        else if (RD1_LOAD) rf1_rp <= 0;
        else if (RD1 && !RD1_EMPTY) rf1_rp <= rf1_rp + 1'b1;
    end

    wire [FFA:0] rd1_ri = rf1_rp + ((RD1 && !RD1_EMPTY) ? 1'b1 : 1'b0);
    always @(posedge RD1_CLK or negedge RESET_N) begin
        if (!RESET_N) rd1_q <= 0;
        else          rd1_q <= rf1[rd1_ri[FFA-1:0]];
    end

    // RD2
    reg [DSIZE-1:0] rf2 [0:FF-1];
    reg [FFA:0]     rf2_wp, rf2_rp;
    reg [ASIZE-1:0] rd2_ptr;
    reg [9:0]       rd2_cnt;
    reg             rd2_busy;
    reg [DSIZE-1:0] rd2_q;

    assign RD2_EMPTY = (rf2_wp == rf2_rp);
    assign RD2_USE   = rf2_wp - rf2_rp;
    assign RD2_DATA  = rd2_q;

    always @(posedge CTRL_CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            rf2_wp <= 0; rd2_ptr <= 0; rd2_cnt <= 0; rd2_busy <= 1'b0;
        end else if (RD2_LOAD) begin
            rf2_wp <= 0; rd2_ptr <= RD2_ADDR; rd2_cnt <= 0; rd2_busy <= 1'b0;
        end else if (!rd2_busy) begin
            if ((rf2_wp - rf2_rp) < RD2_LENGTH) begin
                rd2_busy <= 1'b1; rd2_cnt <= RD2_LENGTH;
            end
        end else begin
            rf2[rf2_wp[FFA-1:0]] <= mem[rd2_ptr];
            rf2_wp  <= rf2_wp + 1'b1;
            rd2_ptr <= (rd2_ptr == RD2_MAX_ADDR - 1'b1) ? RD2_ADDR : rd2_ptr + 1'b1;
            rd2_cnt <= rd2_cnt - 1'b1;
            if (rd2_cnt == 10'd1) rd2_busy <= 1'b0;
        end
    end

    always @(posedge RD2_CLK or negedge RESET_N) begin
        if (!RESET_N)      rf2_rp <= 0;
        else if (RD2_LOAD) rf2_rp <= 0;
        else if (RD2 && !RD2_EMPTY) rf2_rp <= rf2_rp + 1'b1;
    end

    wire [FFA:0] rd2_ri = rf2_rp + ((RD2 && !RD2_EMPTY) ? 1'b1 : 1'b0);
    always @(posedge RD2_CLK or negedge RESET_N) begin
        if (!RESET_N) rd2_q <= 0;
        else          rd2_q <= rf2[rd2_ri[FFA-1:0]];
    end

    // synthesis translate_off
    wire _unused = &{1'b0, SDRAM_CLK};
    // synthesis translate_on

endmodule
