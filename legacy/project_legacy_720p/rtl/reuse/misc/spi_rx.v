 module spi_rx(clk_baud,sck,cs,miso,rst_n,data_out);//接收器设计			    
input clk_baud;//SPI的SCK时钟
input miso,rst_n;
output sck;
output reg cs;
output reg [15:0] data_out;

reg [15:0] clk_baud_cnt=16'd0;
parameter  idle=3'd1,one=3'd2,two=3'd3,stop=3'd4;//状态机的4个状态
reg [2:0] present_state=idle;//状态机当前状态
reg [2:0] next_state=idle;//状态机下一个状态


always @ (posedge clk_baud)
	begin
		if(!rst_n)
			begin
				present_state <= stop;
			end
		else
			begin
				present_state <= next_state;
			end	
	end		

always @ (negedge clk_baud)//根据当前状态机的状态和判断条件, 决定状态机的下一个状态
begin
   	begin
		if(!rst_n)
			begin
				clk_baud_cnt <= 16'd00;
			end
		else
           begin
               clk_baud_cnt <= clk_baud_cnt + 1'b1;
   					if(clk_baud_cnt > 16'd0 && clk_baud_cnt <= 16'd30)//启动，等待ADC转换完成
						next_state <= idle;
					else if(clk_baud_cnt > 16'd30 && clk_baud_cnt <= 16'd46)//接收16位数据
						next_state <= one;
					else if(clk_baud_cnt > 16'd46 && clk_baud_cnt <= 16'd47)//保持
						next_state <= two;
					else if(clk_baud_cnt > 16'd47 && clk_baud_cnt <= 16'd48)//CS拉高
						next_state <= stop;
					else if(clk_baud_cnt == 16'd49)
						clk_baud_cnt <= 16'd00;	
           end
    end
 end	

always @ (posedge clk_baud)	//根据当前状态机的状态, 决定输出
begin
if(!rst_n)
	begin
	  cs <= 1'b1;
	end
else
	begin
		case(next_state)
		idle:	begin
					cs <= 1'b0;
				end				
		one:	begin//接收16位数据
					if(clk_baud_cnt == 16'd32) data_out[15] <= miso;
					else if(clk_baud_cnt == 16'd33) data_out[14] <= miso;
					else if(clk_baud_cnt == 16'd34) data_out[13] <= miso;
					else if(clk_baud_cnt == 16'd35) data_out[12] <= miso;
					else if(clk_baud_cnt == 16'd36) data_out[11] <= miso;
					else if(clk_baud_cnt == 16'd37) data_out[10] <= miso;
					else if(clk_baud_cnt == 16'd38) data_out[9] <= miso;
					else if(clk_baud_cnt == 16'd39) data_out[8] <= miso;
                    else if(clk_baud_cnt == 16'd40) data_out[7] <= miso;
					else if(clk_baud_cnt == 16'd41) data_out[6] <= miso;
					else if(clk_baud_cnt == 16'd42) data_out[5] <= miso;
					else if(clk_baud_cnt == 16'd43) data_out[4] <= miso;
					else if(clk_baud_cnt == 16'd44) data_out[3] <= miso;
					else if(clk_baud_cnt == 16'd45) data_out[2] <= miso;
					else if(clk_baud_cnt == 16'd46) data_out[1] <= miso;
                    else if(clk_baud_cnt == 16'd47) data_out[0] <= miso;
				end				
		two:	begin	//保持								
					cs <= 1'b0;
				end
		stop:	begin						//停止							
					begin
                       cs <= 1'b1;
 					end
           		end
		endcase
	end
end						

assign sck = (next_state == one)? clk_baud : 1'b0;						

endmodule