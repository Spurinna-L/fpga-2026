//=============================================================================
// cdc_sync.v  —  多比特电平量跨时钟域同步（两级同步器）
//-----------------------------------------------------------------------------
// 功能：把异步于 clk_dst 的输入 d_async 送入目的时钟域，降低亚稳态
//       继续传播到后级逻辑的概率。默认使用两级寄存器，q_sync 取最后一级；
//       因此输入变化通常要经过 SYNC_STAGES 个目的时钟沿才反映到输出。
//       这会带来若干拍延迟，但同步器无法保证亚稳态绝不发生。
//
// 适用：慢变、逐位独立的电平/状态量（如图层使能、模式选择、亮度参数）。
// 不适用：多比特总线需要"同时有效"语义时（应用异步 FIFO 或握手），
//         否则可能出现各位到达时刻不一致（多比特偏斜）。
//
// 对真正需要原子性的总线（媒体索引、帧序号），请使用 async_fifo 或
// 格雷码 + 握手（见 doc/框架说明.md 的 CDC 约定）。
//=============================================================================
`timescale 1ns / 1ps

module cdc_sync #(
    parameter WIDTH       = 1,  // 输入、输出位数
    parameter SYNC_STAGES = 2  // 同步寄存器级数（越多亚稳态概率越低，但延迟越大）
)(
    input  wire             clk_dst,    // 目的时钟域
    input  wire             rst_n_dst,  // 目的域复位（低有效）
    input  wire [WIDTH-1:0] d_async,    // 源域信号
    output wire [WIDTH-1:0] q_sync      // 目的域同步结果
);

    // 每一级都由目的时钟采样前一级；第一级直接采样异步输入，
    // 后续级为第一级提供时间消化可能出现的亚稳态。
    reg [WIDTH-1:0] sync_ff [SYNC_STAGES-1:0];
    integer i;

    always @(posedge clk_dst or negedge rst_n_dst) begin
        if (!rst_n_dst) begin
            // 目的域复位时清空整个同步流水线。
            for (i = 0; i < SYNC_STAGES; i = i + 1)
                sync_ff[i] <= {WIDTH{1'b0}};
        end else begin
            // 非阻塞赋值让每一级在同一时钟沿读取前一拍的值，形成流水传递。
            sync_ff[0] <= d_async;
            for (i = 1; i < SYNC_STAGES; i = i + 1)
                sync_ff[i] <= sync_ff[i-1];
        end
    end

    // 输出只取同步链末级，不直接使用异步输入或中间级。
    assign q_sync = sync_ff[SYNC_STAGES-1];

endmodule
