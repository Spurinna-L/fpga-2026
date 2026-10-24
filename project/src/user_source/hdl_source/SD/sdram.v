//=============================================================================
// sdram.v — SDRAM 用户接口封装（安路 sdr_as_ram + 片外硬核模型）
//-----------------------------------------------------------------------------
// 功能：
//   对外提供 32bit / 21bit 地址的简单读写接口（App_*），内部由加密控制器
//   sdr_as_ram 完成上电初始化、自刷新、行/列命令与数据收发；再例化
//   EG_PHY_SDRAM_2M_32 把命令/地址/数据接到片外 SDRAM 引脚。
//
// 时钟：
//   Clk     = 125MHz（控制器主时钟）
//   Clk_sft = 125MHz 移相 180°（SDRAM_CLK 输出，保证建立/保持窗口）
// 复位：Rst 高有效。
//
// 接口：
//   写：App_wr_en / App_wr_addr[20:0] / App_wr_dm[3:0] / App_wr_din[31:0]
//   读：App_rd_en / App_rd_addr[20:0] → Sdr_rd_en / Sdr_rd_dout[31:0]
//   状态：Sdr_init_done / Sdr_init_ref_vld / Sdr_busy
//
// 常量（来自 include/global_def.v）：
//   DATA_WIDTH=32、ADDR_WIDTH=21、DM_WIDTH=4、ROW_WIDTH=11、BA_WIDTH=2
//
// 内部例化：
//   sdr_as_ram           加密 SDRAM 控制器（`pragma protect，不可读）
//   EG_PHY_SDRAM_2M_32   安路 SDRAM 硬核模型（接 dq/addr/ba/ras/cas/we）
//
// 备注：
//   仿真（`SIMULATION）时端口表会展开出 SDRAM 引脚；
//   综合时 SDRAM_DQ 为 inout，DQ 路径在 timing.sdc 中按厂商惯例设 false path。
//=============================================================================
`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: anlgoic
// Author: 	xg 
// description:  top module
//////////////////////////////////////////////////////////////////////////////////

`define DEBUG

`include "../user_source/hdl_source/include/global_def.v"

module sdram(
    `ifdef SIMULATION
	output					SDRAM_CLK,
	output					SDR_CKE,
	output					SDR_RAS,
	output					SDR_CAS,
	output					SDR_WE,
	output	[`BA_WIDTH-1:0]	SDR_BA,
	output	[`ROW_WIDTH-1:0]SDR_ADDR,
	output	[`DM_WIDTH-1:0]	SDR_DM,
	inout	[`DATA_WIDTH-1:0]	SDR_DQ,	
	`endif
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	//synthesis keep
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	//synthesis keep
    
    
    
);
`ifndef SIMULATION
wire  			SDRAM_CLK;
wire 			SDR_RAS;
wire  			SDR_CAS;
wire  			SDR_WE;
wire  [`BA_WIDTH-1:0]	SDR_BA; 
wire  [`ROW_WIDTH-1:0]	SDR_ADDR;
wire  [`DATA_WIDTH-1:0]	SDR_DQ ;
wire  [`DM_WIDTH-1:0]	SDR_DM; 
`endif

sdr_as_ram  #( .self_refresh_open(1'b1))
	u2_ram( 
		.Sdr_clk(Clk),
		.Sdr_clk_sft(Clk_sft),
		.Rst(Rst),
			  			  
		.Sdr_init_done(Sdr_init_done),
		.Sdr_init_ref_vld(Sdr_init_ref_vld),
		.Sdr_busy(Sdr_busy),
		
		.App_ref_req(1'b0),
		
        .App_wr_en(App_wr_en), 
        .App_wr_addr(App_wr_addr),  	
		.App_wr_dm(App_wr_dm),
		.App_wr_din(App_wr_din),

		.App_rd_en(App_rd_en),
		.App_rd_addr(App_rd_addr),
		.Sdr_rd_en	(Sdr_rd_en),
		.Sdr_rd_dout(Sdr_rd_dout),
	
		.SDRAM_CLK(SDRAM_CLK),
		.SDR_RAS(SDR_RAS),
		.SDR_CAS(SDR_CAS),
		.SDR_WE(SDR_WE),
		.SDR_BA(SDR_BA),
		.SDR_ADDR(SDR_ADDR),
		.SDR_DM(SDR_DM),
		.SDR_DQ(SDR_DQ)	
	);


assign SDR_CKE=1'b1;

//`ifndef SIMULATION
	EG_PHY_SDRAM_2M_32 sdram(
		.clk(SDRAM_CLK),
		.ras_n(SDR_RAS),
		.cas_n(SDR_CAS),
		.we_n(SDR_WE),
		.addr(SDR_ADDR[10:0]),
		.ba(SDR_BA),
		.dq(SDR_DQ),
		.cs_n(1'b0),
		.dm0(SDR_DM[0]),
		.dm1(SDR_DM[1]),
		.dm2(SDR_DM[2]),
		.dm3(SDR_DM[3]),
		.cke(1'b1)
		);
//`endif

endmodule 
