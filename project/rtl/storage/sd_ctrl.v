//=============================================================================
// sd_ctrl.v  —  SD 卡 SPI 底层控制器（复用官方 sd_initial/sd_read + 异步 FIFO）
//-----------------------------------------------------------------------------
// 复用：rtl/reuse/sd/sd_initial.v（CMD0/CMD8/CMD55/ACMD41 初始化）、
//       rtl/reuse/sd/sd_read.v（CMD17 单块读，512B）、sd_pll.v（25MHz）。
// 自研：请求/完成握手、跨时钟域字节 FIFO（SD_clk 25MHz → 系统 50MHz）。
//
// 数据流：rd_req(50M) → 同步到 SD 域 → CMD17 读一个 512B 块 → 字节写入
//         异步 FIFO(512x8) → 50M 侧 rd_valid/rd_data 流式读出（供 FAT32 解析）。
//
// 上层 fat32_reader 以"扇区(512B)"为单位请求，本模块不做文件系统语义。
//=============================================================================
`timescale 1ns / 1ps

module sd_ctrl (
    input  wire        clk,          // 系统 50MHz
    input  wire        rst_n,

    // 物理 SD 接口（SPI 模式）
    output wire        sd_clk,       // F15
    output wire        sd_cs,        // F13
    output wire        sd_mosi,      // F14
    input  wire        sd_miso,      // D14

    // 扇区读请求 / 数据流（系统时钟域）
    input  wire [31:0] rd_sec,       // 逻辑块地址（512B/块）
    input  wire        rd_req,       // 单拍请求
    output wire [7:0]  rd_data,
    output wire        rd_valid,     // rd_data 有效
    input  wire        rd_pop,       // 取出一个字节
    output wire        rd_done,      // 本扇区读完成（单拍）

    // 状态
    output wire        init_done
);

    wire sd_clk_i;
    wire sd_cs_i, sd_mosi_i, sd_csr, sd_mosir;
    wire init_o;
    wire [7:0] mydata_o;
    wire myvalid_o, read_o;

    // 25MHz SD 时钟
    sd_pll u_sd_pll (
        .refclk (clk),
        .reset  (~rst_n),
        .clk0_out(sd_clk_i)
    );
    assign sd_clk = sd_clk_i;

    // 初始化
    sd_initial u_sd_initial (
        .rst_n     (rst_n),
        .SD_clk    (sd_clk_i),
        .SD_cs     (sd_cs_i),
        .SD_datain (sd_mosi_i),
        .SD_dataout(sd_miso),
        .rx        (),
        .init_o    (init_o),
        .state     ()
    );
    assign init_done = init_o;

    // ---- 请求电平（50M）→ 同步到 SD 域 ----
    reg rd_req_l;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_req_l <= 1'b0;
        else if (rd_req) rd_req_l <= 1'b1;
        else if (rd_done) rd_req_l <= 1'b0;
    end

    wire rd_req_sd;
    cdc_sync #(.WIDTH(1)) u_req_sync (
        .clk_dst  (sd_clk_i),
        .rst_n_dst(1'b1),
        .d_async  (rd_req_l),
        .q_sync   (rd_req_sd)
    );

    // 单块读
    sd_read u_sd_read (
        .SD_clk    (sd_clk_i),
        .SD_cs     (sd_csr),
        .SD_datain (sd_mosir),
        .SD_dataout(sd_miso),
        .sec       (rd_sec),
        .read_req  (rd_req_sd & init_o),
        .mydata_o  (mydata_o),
        .myvalid_o (myvalid_o),
        .data_come (),
        .init      (init_o),
        .mystate   (),
        .read_o    (read_o)
    );

    // ---- 读完成：SD 域 → 系统域 ----
    wire read_o_sys;
    cdc_sync #(.WIDTH(1)) u_done_sync (
        .clk_dst  (clk),
        .rst_n_dst(rst_n),
        .d_async  (read_o),
        .q_sync   (read_o_sys)
    );

    // 读完成脉冲（边沿检测）
    reg read_o_sys_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) read_o_sys_d <= 1'b0;
        else        read_o_sys_d <= read_o_sys;
    end
    assign rd_done = read_o_sys & ~read_o_sys_d;

    // ---- 字节 FIFO：SD 域写 → 系统域读 ----
    wire fifo_empty;
    async_fifo #(.DW(8), .DEPTH(512)) u_byte_fifo (
        .wr_clk  (sd_clk_i),
        .wr_rst_n(rst_n),
        .wr_en   (myvalid_o),
        .wr_data (mydata_o),
        .full    (),
        .rd_clk  (clk),
        .rd_rst_n(rst_n),
        .rd_en   (rd_pop & rd_valid),
        .rd_data (rd_data),
        .empty   (fifo_empty)
    );

    // 组合读数据，故 valid = !empty
    assign rd_valid = ~fifo_empty;

    // ---- cs/datain 复用（初始化阶段用初始化的，其余用读的） ----
    wire use_init = ~init_o;
    assign sd_cs   = use_init ? sd_cs_i  : sd_csr;
    assign sd_mosi = use_init ? sd_mosi_i: sd_mosir;

endmodule
