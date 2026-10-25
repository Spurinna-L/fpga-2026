//=============================================================================
// video_timing_data.v — 视频时序发生 + 每帧读请求
//-----------------------------------------------------------------------------
// 功能：
//   1) 内部 color_bar 产生 640×480@60 的 hs/vs/de（负极性，25MHz 像素时钟），
//      本模块把三路各延迟 2 拍后输出，作为全系统的像素时序基准；
//   2) 在每帧 vs 下降沿拉高 read_req，等 read_req_ack 后撤销，通知帧缓存
//      “开始送下一帧”。
//
// 时钟/复位：video_clk = 25MHz；rst 高有效。
//
// 接口：
//   out read_req / in read_req_ack    每帧一次的读请求握手
//   out hs / vs / de                  延迟 2 拍的视频时序
//   out v_cnt[11:0]                   行计数，供 M2 行读取调度使用
//
// 参数：
//   DATA_WIDTH = 16   历史遗留参数，本模块不再传像素数据
//
// 内部例化：
//   color_bar（rgb_r/g/b 输出悬空；仅借用其时序发生器，显示彩条由
//   test_pattern_640x480 负责）
//
// 备注：
//   read_req_ack 来自 125MHz 域，已做 2FF 同步后再撤销 read_req，
//   避免异步信号直接进状态机。
//=============================================================================
module video_timing_data
#(
	parameter DATA_WIDTH = 16                       // Video data one clock data width
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output reg                  read_req,           // Start reading a frame of data     
	input                       read_req_ack,       // Read request response
	//output                      read_en,            // Read data enable
	//input[DATA_WIDTH - 1:0]     read_data,          // Read data
	output                      hs,                 // horizontal synchronization
	output                      vs,                 // vertical synchronization
	output                      de,                 // video valid
	output[11:0]                v_cnt               // vertical line counter (M2)
	//output[DATA_WIDTH - 1:0]    vout_data           // video data
);
wire                   video_hs;
wire                   video_vs;
wire                   video_de;
//delay video_hs video_vs  video_de 2 clock cycles
reg                    video_hs_d0;
reg                    video_vs_d0;
reg                    video_de_d0;
reg                    video_hs_d1;
reg                    video_vs_d1;
reg                    video_de_d1;

//reg[DATA_WIDTH - 1:0]  vout_data_r;
//assign read_en = video_de;
assign hs = video_hs_d1;
assign vs = video_vs_d1;
assign de = video_de_d1;
//assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		video_hs_d0 <= 1'b0;
		video_vs_d0 <= 1'b0;
		video_de_d0 <= 1'b0;
	end
	else
	begin
		//delay video_hs video_vs  video_de 2 clock cycles
		video_hs_d0 <= video_hs;
		video_vs_d0 <= video_vs;
		video_de_d0 <= video_de;
		video_hs_d1 <= video_hs_d0;
		video_vs_d1 <= video_vs_d0;
		video_de_d1 <= video_de_d0;		
	end
end
/*
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(video_de_d0)
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
*/
// read_req_ack 来自 125MHz SDRAM 域，2FF 同步后再撤销 read_req
reg [1:0] ack_sync;
wire read_req_ack_s = ack_sync[1];

always @(posedge video_clk or posedge rst)
begin
    if (rst == 1'b1)
        ack_sync <= 2'b00;
    else
        ack_sync <= {ack_sync[0], read_req_ack};
end

always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		read_req <= 1'b0;
	else if(video_vs_d0 & ~video_vs) //vertical synchronization edge (the rising or falling edges are OK)
		read_req <= 1'b1;
	else if(read_req_ack_s)
		read_req <= 1'b0;
end

color_bar color_bar_m0(
	.clk(video_clk),
	.rst(rst),
	.hs(video_hs),
	.vs(video_vs),
	.de(video_de),
	.o_v_cnt(v_cnt),
	.rgb_r(),
	.rgb_g(),
	.rgb_b()
);
endmodule 
