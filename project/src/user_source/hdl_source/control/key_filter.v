//=============================================================================
// key_filter.v — 16 路按键电平消抖
//-----------------------------------------------------------------------------
// 功能：
//   每 CNTMAX+1 个 clk（50MHz 下约 20ms）采样一次 key_in，保存最近三次采样；
//   当“当前”和“上一次”采样都为低时判为按下，输出高电平。
//   等价于连续两个 20ms 采样点一致才更新，可滤掉短于 20ms 的抖动。
//
// 时钟/复位：clk = 50MHz；rstn 低有效。
//
// 接口：
//   in  key_in[15:0]   原始键值（按下 = 0）
//   out key_deb[15:0]  消抖后键值（按下 = 1，电平，不是单拍脉冲）
//
// 参数：
//   CNTMAX = 999_999   20ms 采样分频（50MHz × 20ms）
//
// 内部例化：无
//
// 备注：
//   输出是电平而不是脉冲；regs.v 内部再做上升沿检测得到 key_press。
//=============================================================================
module key_filter(clk,rstn,key_in,key_deb);
    input clk;
    input rstn;
    input [15:0] key_in;
    output [15:0] key_deb;
    //分频计数
    parameter CNTMAX = 999_999;
    reg [19:0] cnt = 0;
    always@(posedge clk or negedge rstn) begin
        if(~rstn)
            cnt <= 0;
        else if(cnt == CNTMAX)
            cnt <= 0;
        else
            cnt <= cnt + 1'b1;
     end
     //每20ms采样一次按键电平
     reg [15:0] key_reg0;
     reg [15:0] key_reg1;
     reg [15:0] key_reg2; 
     always@(posedge clk or negedge rstn) begin
        if(~rstn) begin
            key_reg0 <= 16'hffff;
            key_reg1 <= 16'hffff;
            key_reg2 <= 16'hffff;
        end
        else if(cnt == CNTMAX) begin
            key_reg0 <= key_in;
            key_reg1 <= key_reg0;
            key_reg2 <= key_reg1;
        end
    end
     //这里判定两种情况下按键被按下，一是三个按键寄存器都为低电平，这显然是按键稳定的情况，第二种是40ms前的按键信号为高电平，而20ms前的按键信号和当前的按键信号为低电平
    assign key_deb = (~key_reg0 & ~key_reg1 & ~key_reg2) | (~key_reg0 & ~key_reg1 & key_reg2);
endmodule
            
        
