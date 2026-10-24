`timescale 1ns/1ps
//=============================================================================
// sdram_bhv.v — 供 iverilog 仿真用的简化 SDRAM 行为模型
//-----------------------------------------------------------------------------
// 只模拟 sdr_as_ram 的用户侧时序：单周期写、固定 LATENCY 拍读流水。
// 不模拟行/列/刷新时序（这些由官方加密核保证），因此仅用于验证
// frame_read_write_dual 的地址生成、FIFO 与读仲裁逻辑。
//=============================================================================
module sdram_bhv #(
    parameter ADDR_BITS = 21,
    parameter DATA_BITS = 32,
    parameter LATENCY   = 3,
    parameter INIT_CYCLES = 100
)(
    input  wire                  clk,
    input  wire                  rst,

    input  wire                  App_wr_en,
    input  wire [ADDR_BITS-1:0]  App_wr_addr,
    input  wire [DATA_BITS-1:0]  App_wr_din,
    input  wire [3:0]            App_wr_dm,

    input  wire                  App_rd_en,
    input  wire [ADDR_BITS-1:0]  App_rd_addr,
    output wire                  Sdr_rd_en,
    output wire [DATA_BITS-1:0]  Sdr_rd_dout,

    output reg                   Sdr_init_done,
    output wire                  Sdr_init_ref_vld,
    output wire                  Sdr_busy
);

    reg [DATA_BITS-1:0] mem [0:(1<<ADDR_BITS)-1];
    reg [LATENCY-1:0]   vld;
    reg [DATA_BITS-1:0] pipe [0:LATENCY-1];

    integer k;
    reg [7:0] init_cnt;

    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy         = 1'b0;
    assign Sdr_rd_en        = vld[LATENCY-1];
    assign Sdr_rd_dout      = pipe[LATENCY-1];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            init_cnt      <= 8'd0;
            Sdr_init_done <= 1'b0;
        end else if (!Sdr_init_done) begin
            if (init_cnt >= 8'd100)
                Sdr_init_done <= 1'b1;
            else
                init_cnt <= init_cnt + 8'd1;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vld <= {LATENCY{1'b0}};
            for (k = 0; k < LATENCY; k = k + 1)
                pipe[k] <= {DATA_BITS{1'b0}};
        end else begin
            if (App_wr_en)
                mem[App_wr_addr] <= App_wr_din;

            vld[0]  <= App_rd_en;
            pipe[0] <= mem[App_rd_addr];

            for (k = 1; k < LATENCY; k = k + 1) begin
                vld[k]  <= vld[k-1];
                pipe[k] <= pipe[k-1];
            end
        end
    end

endmodule
