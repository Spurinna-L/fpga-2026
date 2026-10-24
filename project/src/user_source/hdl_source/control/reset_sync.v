//=============================================================================
// reset_sync.v — 单时钟域“异步置位 / 同步释放”复位同步器
//-----------------------------------------------------------------------------
// 功能：
//   合并全局异步复位 rst_n_in 与另一时钟域来的 por_done，产生本域低有效复位
//   rst_n_out：rst_n_in=0 时立即复位；por_done 经 2FF 同步后，用移位寄存器
//   逐拍释放，保证释放沿只可能出现在 clk 上升沿之后，满足 recovery/removal。
//
// 时钟/复位：
//   clk 为本域工作时钟；rst_n_in 为低有效异步复位。
//
// 接口：
//   in  clk        本域时钟
//   in  rst_n_in   外部/全局异步复位（低有效）
//   in  por_done   50MHz 域 POR 完成电平（异步，内部先 2FF）
//   out rst_n_out  本域复位（低有效，异步置位、同步释放）
//
// 参数：
//   STAGES = 2     释放移位级数（>=2）
//
// 内部例化：无
//
// 备注：
//   下游若使用高有效复位，顶层取反即可（rst_* = ~rst_n_*）。
//=============================================================================
`timescale 1ns/1ps

module reset_sync #(
    parameter integer STAGES = 2
)(
    input  wire clk,
    input  wire rst_n_in,      // 外部/全局异步复位，低有效
    input  wire por_done,      // 来自 50MHz 域的 POR 完成电平（异步）
    output wire rst_n_out
);

    reg [1:0] por_sync;
    reg [STAGES-1:0] rstq;

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in)
            por_sync <= 2'b00;
        else
            por_sync <= {por_sync[0], por_done};
    end

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in)
            rstq <= {STAGES{1'b0}};
        else if (!por_sync[1])
            rstq <= {STAGES{1'b0}};              // 保持复位
        else
            rstq <= {rstq[STAGES-2:0], 1'b1};    // 同步释放
    end

    assign rst_n_out = rstq[STAGES-1];

endmodule
