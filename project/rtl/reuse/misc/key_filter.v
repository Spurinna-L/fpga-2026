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
            
        