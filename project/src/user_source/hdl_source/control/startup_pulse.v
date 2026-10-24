//=============================================================================
// startup_pulse.v — 上电延时单拍脉冲发生器
//-----------------------------------------------------------------------------
// 功能：
//   复位释放后开始计数，计满 CNT_MAX 个时钟输出一拍 O_pulse，之后不再产生。
//
// 时钟/复位：I_clk 为工作时钟；I_rst 高有效。
//
// 接口：
//   out O_pulse   单拍脉冲（宽度 = 1 个 I_clk 周期）
//
// 参数：
//   CNT_MAX = 100000   50MHz 下约 2ms
//
// 内部例化：无
//
// 备注：
//   当前工程未例化（顶层用 POR 计数 + reset_sync 实现上电延时），保留备用。
//=============================================================================
module startup_pulse #(
    parameter [19:0] CNT_MAX = 20'd100000
)(
    input  wire I_clk,
    input  wire I_rst,
    output reg  O_pulse
);

reg [19:0] S_cnt;
reg        S_done;

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        S_cnt   <= 20'd0;
        S_done  <= 1'b0;
        O_pulse <= 1'b0;
    end
    else begin
        O_pulse <= 1'b0;

        if (!S_done) begin
            if (S_cnt == CNT_MAX - 1'b1) begin
                S_cnt   <= S_cnt;
                S_done  <= 1'b1;
                O_pulse <= 1'b1;
            end
            else begin
                S_cnt <= S_cnt + 1'b1;
            end
        end
    end
end

endmodule
