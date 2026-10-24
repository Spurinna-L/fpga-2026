//=============================================================================
// ax_debounce.v — 通用按键消抖（输出稳定电平 + 上/下沿脉冲）
//-----------------------------------------------------------------------------
// 功能：
//   用两级同步 + 20ms 稳定计数器滤除抖动，得到 button_out；
//   再打一拍产生 button_posedge / button_negedge 单拍脉冲。
//
// 时钟/复位：clk（默认按 50MHz 参数计算）；rst 高有效。
//
// 接口：
//   in  button_in
//   out button_out / button_posedge / button_negedge
//
// 参数：
//   N = 32           计数器位宽
//   FREQ = 50        时钟频率（MHz），用于换算 20ms
//   MAX_TIME = 20    消抖时间（ms）
//   TIMER_MAX_VAL = MAX_TIME*1000*FREQ
//
// 内部例化：无
//
// 备注：
//   当前工程未例化（键盘用 key_filter + key_press_debounce），保留备用。
//=============================================================================
module  ax_debounce 
(
    input       clk, 
    input       rst, 
    input       button_in,
    output reg  button_posedge,
    output reg  button_negedge,
    output reg  button_out
);
//// ---------------- internal constants --------------
parameter N = 32 ;           // debounce timer bitwidth
parameter FREQ = 50;         //model clock :Mhz
parameter MAX_TIME = 20;     //ms
localparam TIMER_MAX_VAL =   MAX_TIME * 1000 * FREQ;
////---------------- internal variables ---------------
reg  [N-1 : 0]  q_reg;      // timing regs
reg  [N-1 : 0]  q_next;
reg DFF1, DFF2;             // input flip-flops
wire q_add;                 // control flags
wire q_reset;
reg button_out_d0;
//// ------------------------------------------------------

////contenious assignment for counter control
assign q_reset = (DFF1  ^ DFF2);          // xor input flip flops to look for level chage to reset counter
assign q_add = ~(q_reg == TIMER_MAX_VAL); // add to counter when q_reg msb is equal to 0
    
//// combo counter to manage q_next 
always @ ( q_reset, q_add, q_reg)
begin
    case( {q_reset , q_add})
        2'b00 :
                q_next <= q_reg;
        2'b01 :
                q_next <= q_reg + 1;
        default :
                q_next <= { N {1'b0} };
    endcase     
end

//// Flip flop inputs and q_reg update
always @ ( posedge clk or posedge rst)
begin
    if(rst == 1'b1)
    begin
        DFF1 <= 1'b0;
        DFF2 <= 1'b0;
        q_reg <= { N {1'b0} };
    end
    else
    begin
        DFF1 <= button_in;
        DFF2 <= DFF1;
        q_reg <= q_next;
    end
end

//// counter control
always @ ( posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		button_out <= 1'b1;
    else if(q_reg == TIMER_MAX_VAL)
        button_out <= DFF2;
    else
        button_out <= button_out;
end

always @ ( posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		button_out_d0 <= 1'b1;
		button_posedge <= 1'b0;
		button_negedge <= 1'b0;
	end
	else
	begin
		button_out_d0 <= button_out;
		button_posedge <= ~button_out_d0 & button_out;
		button_negedge <= button_out_d0 & ~button_out;
	end	
end
endmodule


