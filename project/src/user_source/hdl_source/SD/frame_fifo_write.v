//=============================================================================
// frame_fifo_write.v 鈥?甯х紦瀛樺啓閫氶亾绐佸彂 FSM
//-----------------------------------------------------------------------------
// 鍔熻兘锛?
//   鏀跺埌 write_req 鍚庯細娓呯┖鍐?FIFO銆侀攣瀛樺熀鍦板潃涓庡抚闀垮害 鈫?鍦?S_CHECK_FIFO
//   鍒ゆ柇 FIFO 姘翠綅鏄惁澶熶竴娆＄獊鍙戯紙涓旇閫氶亾涓嶅繖锛夆啋 杩炵画鍙?BURST_SIZE 涓?
//   App_wr_en/App_wr_addr 鎶婃暟鎹啓杩?SDRAM 鈫?绱鍐欐弧 write_len 鍚庣粰
//   write_finish 涓€鎷嶃€?
//
// 鏃堕挓/澶嶄綅锛歮em_clk = 125MHz锛況st 楂樻湁鏁堛€?
//
// 鎺ュ彛锛?
//   write_req / write_req_ack / write_finish
//   write_addr_0..3[20:0] / write_addr_index[1:0] / write_len[20:0]
//   rdusedw[9:0]     鍐?FIFO 涓凡鏈夊瓧鏁帮紙璇讳晶瑙嗚鐨勬按浣嶏級
//   fifo_aclr        娓呯┖鍐?FIFO
//   App_wr_en / App_wr_addr[20:0]
//   App_rd_busy      璇婚€氶亾蹇欙紝閬垮厤璇诲啓鍚屾椂鎶㈡€荤嚎
//   O_wr_busy        鏈€氶亾姝ｅ湪/鍗冲皢绐佸彂锛堢粰璇婚€氶亾璁╄矾锛?
//
// 鍙傛暟锛?
//   MEM_DATA_BITS=32銆丄DDR_BITS=21銆丅URST_BITS=9銆丅URST_SIZE=128
//   WRITE_V_FLIP=1銆丗RAME_WIDTH=640銆丗RAME_HEIGHT=480
//   锛堟湰宸ョ▼鐢?frame_read_write 浼犲叆 BURST_SIZE=256锛?
// 甯搁噺锛?
//   S_IDLE / S_ACK / S_CHECK_FIFO / S_WRITE_BURST / S_WRITE_BURST_END / S_END
//   VFLIP_FIRST_ADDR_OFFSET = (480-1)*640 = 306560
//   VFLIP_LINE_JUMP         = 640*2-1   = 1279
//
// 鍐呴儴渚嬪寲锛氭棤
//
// 澶囨敞锛圡1 閲嶇偣锛夛細
//   rdusedw_r / app_rd_busy_r / into_burst 鍚勬墦涓€鎷嶏紝鏄负鍒囨柇 125MHz 涓?
//   鈥淔IFO 璇绘寚閽?鈫?21bit 姣旇緝 鈫?璇?FSM鈥?鐨勯暱缁勫悎璺緞锛堝師 -0.698ns 杩濅緥锛夈€?
//   杩欎笁鎷嶇洿鎺ュ喅瀹氣€滀綍鏃跺厑璁稿惎鍔ㄥ啓绐佸彂鈥濓紝鎺掓煡妯甫鏃朵紭鍏堟€€鐤戣繖閲屻€?
//=============================================================================
`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      rdusedw,                    // from fifo read used words
	input                           App_wr_sop                  // 琛岄鏍囧織锛堟暟鎹?bit0锛夛紝涓?App_wr_en 鍚屾媿
);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'

// Vertical flip address mapping for 640x480 frame buffer.
// Input stream order remains unchanged; only SDRAM write addresses are remapped:
// stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_STEP         = FRAME_WIDTH;
localparam [15:0]            VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1;

//write state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for write
localparam S_ACK                     = 1;                        //written request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
localparam S_WRITE_BURST             = 3;                        //begin a burst write
localparam S_WRITE_BURST_END         = 4;                        //a burst write complete
localparam S_END                     = 5;                        //a frame of data is written to complete


reg                                 write_req_d0;                //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
reg                                 write_req_d1;                //the second
reg                                 write_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                write_len_d1;                //second
reg[ADDR_BITS - 1:0]                write_len_latch;             //lock write data length
reg[ADDR_BITS - 1:0]                write_cnt;                   //write data counter
reg[1:0]                            write_addr_index_d0;
reg[1:0]                            write_addr_index_d1;
reg[3:0]                            state;                       //state machine
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg [ADDR_BITS - 1:0]	 row_start_r;                // 褰撳墠琛岄鍦板潃锛堣棣栨爣蹇楀埌鏉ヨ嚜澧?閫掑噺锛?
reg                      sop_mode;                   // 鏈抚宸茶鍒拌棣栨爣蹇楋紝鏀圭敤鏄惧紡琛屽榻?
reg [15:0]                            wr_x;                       // current x position in one input row

reg [BURST_BITS - 1:0]				burst_cnt;
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

// 鍐欑獊鍙戞潯浠讹細rdusedw / App_rd_busy 鍏堝悇鎵撲竴鎷嶏紝鍒囨柇
// 鈥滃紓姝?FIFO 璇绘寚閽?-> 21bit 姣旇緝 -> 璇?FSM鈥?鍦?125MHz 涓嬬殑闀跨粍鍚堣矾寰?
// 锛圡0 鎶ュ憡涓殑 -0.698ns 杩濅緥鍗虫潵鑷澶勶級銆?
reg [9:0] rdusedw_r;
reg       app_rd_busy_r;

always @(posedge mem_clk or posedge rst) begin
	if (rst) begin
		rdusedw_r      <= 10'd0;
		app_rd_busy_r  <= 1'b0;
	end else begin
		rdusedw_r      <= rdusedw;
		app_rd_busy_r  <= App_rd_busy;
	end
end

wire into_burst_c;
assign into_burst_c = (((write_len_latch <= (rdusedw_r + write_cnt)) || rdusedw_r > BURST_SIZE) && ~app_rd_busy_r);//褰搑d鍦ㄧ獊鍙戞椂涓嶄細杩涘叆burst

// into_burst 鎵囧嚭鍒?O_wr_busy -> 璇?FSM / rd_arbiter锛屽啀鎵撲竴鎷嶅垏鏂?125MHz 闀胯矾寰?
reg into_burst;
always @(posedge mem_clk or posedge rst) begin
	if (rst)
		into_burst <= 1'b0;
	else
		into_burst <= into_burst_c;
end

// into_burst 鎵囧嚭鍒?O_wr_busy -> 璇?FSM锛屾墦涓€鎷嶅垏鏂?125MHz 闀胯矾寰?

// 琛岄瀛楋紙sop锛夌殑鍦板潃鐩存帴鐢?row_start_r 缁勫悎缁欏嚭锛欶IFO 闃熷ご甯﹁棣栨爣蹇楋紝
// 杩欐牱鏃犺涓婁竴琛屽疄闄呮敹浜嗗灏戜釜瀛楋紝鏈绗竴涓儚绱犱竴瀹氳惤鍦ㄨ棣栥€?
wire [ADDR_BITS - 1:0] next_row_start = row_start_r - VFLIP_LINE_STEP;

assign App_wr_addr = (WRITE_V_FLIP && App_wr_sop) ? next_row_start : App_wr_addr_r;
//assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//鍦ㄧ獊鍙戯紝鎴栬€呭皢瑕佺獊鍙戯紝鍒欐樉绀篵usy
assign wr_burst_finish = (burst_cnt >= BURST_SIZE);
assign write_finish = (state == S_END) ? 1'b1 : 1'b0;            //write finish at state 'S_END'
assign App_wr_en = App_wr_en_d0;


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d1 <= 0;
		write_addr_index_d0    <=  2'b00;
		write_addr_index_d1    <=  2'b00;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
		if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		row_start_r   <= ZERO[ADDR_BITS - 1:0];
		sop_mode      <= 1'b0;
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_wr_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				wr_x <= 16'd0;
				sop_mode <= 1'b0;
				if(write_addr_index_d1 == 2'd0)
					begin
						App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_0 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_0;
						row_start_r   <= (WRITE_V_FLIP ? (write_addr_0 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_0) + VFLIP_LINE_STEP;
					end
				else if(write_addr_index_d1 == 2'd1)
					begin
						App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_1 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_1;
						row_start_r   <= (WRITE_V_FLIP ? (write_addr_1 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_1) + VFLIP_LINE_STEP;
					end
				else if(write_addr_index_d1 == 2'd2)
					begin
						App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_2 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_2;
						row_start_r   <= (WRITE_V_FLIP ? (write_addr_2 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_2) + VFLIP_LINE_STEP;
					end
				else
					begin
						App_wr_addr_r <= WRITE_V_FLIP ? (write_addr_3 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_3;
						row_start_r   <= (WRITE_V_FLIP ? (write_addr_3 + VFLIP_FIRST_ADDR_OFFSET) : write_addr_3) + VFLIP_LINE_STEP;
					end
			end
		else if(App_wr_en)
			begin
				if(App_wr_sop)
					sop_mode <= 1'b1;
				if(WRITE_V_FLIP)
				begin
					if(App_wr_sop)
					begin
						// 鏄惧紡琛岄瀵归綈锛氭柊琛岄 = 涓婁竴琛岄 - 640锛屼笌涓婁竴琛屽疄闄呮敹鍒板灏戜釜瀛楁棤鍏炽€?
						// 杩欐牱鍗充娇鏌愯灏?澶氫竴涓瓧锛岃宸篃涓嶄細閫愯绱Н鎴愭枩鍒囥€?
						wr_x          <= 16'd0;
						row_start_r   <= next_row_start;
						App_wr_addr_r <= next_row_start + 1'b1;
					end
					else if(!sop_mode && (wr_x == VFLIP_LINE_LAST_X))
					begin
						// 鍏煎娌℃湁琛岄鏍囧織鐨勬棫鏁版嵁娴侊紙鍐呯疆娴嬭瘯鍥炬绛夛級
						wr_x <= 16'd0;
						App_wr_addr_r <= App_wr_addr_r - VFLIP_LINE_JUMP;
					end
					else
					begin
						wr_x <= wr_x + 1'b1;
						App_wr_addr_r <= App_wr_addr_r + 1'b1;
					end
				end
				else
					App_wr_addr_r <= App_wr_addr_r + 1'b1;
			end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		if(App_wr_en_r && burst_cnt + App_wr_en < BURST_SIZE && (burst_cnt + write_cnt + App_wr_en < write_len_latch))begin
            App_wr_en_d0 <= 1'b1;
        end
		else
			App_wr_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else 
		case(state)
			//idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(write_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				//after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
				if(write_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					//write request response
					write_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					//latch data length
					write_len_latch <= write_len_d1;                    
				end
				//write data counter reset, write_cnt <= 0;
				write_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst write request, goto burst write state
				else if(into_burst)
				begin
					state <= S_WRITE_BURST;
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				//burst finish
				if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					//write counter + burst length
					write_cnt <= write_cnt + BURST_SIZE[ADDR_BITS - 1:0];
					//the next burst write address is generated
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the write counter value is less than the frame length, continue writing,
				//otherwise the writing is complete
				else if(write_cnt < write_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule
