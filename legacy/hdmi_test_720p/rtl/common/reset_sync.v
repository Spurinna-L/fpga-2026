//=============================================================================
// reset_sync.v  —  异步复位同步释放
//-----------------------------------------------------------------------------
// 用途：把板载按键/开关产生的异步复位，同步到某个时钟域后再释放，
//       避免释放边沿造成触发器亚稳态。
//
// 复位约定（全局）：低电平有效 rst_n。
//   异步拉低（assert）  : 立即生效，保证任何时钟下都能复位；
//   同步释放（deassert）: 经 2 级触发器同步。
//=============================================================================
`timescale 1ns / 1ps

module reset_sync #(
    parameter SYNC_STAGES = 2   // 同步寄存器级数（越多亚稳态概率越低，但延迟越大）
)(
    input  wire clk,        // 目标时钟域时钟
    input  wire arst_n,     // 异步复位输入（低有效）
    output wire rst_n       // 同步后的复位输出（低有效）
);

    reg [SYNC_STAGES-1:0] sync_ff;

    always @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync_ff <= {SYNC_STAGES{1'b0}};
        else
            sync_ff <= {sync_ff[0], 1'b1};
    end

    assign rst_n = sync_ff[SYNC_STAGES-1];

endmodule
