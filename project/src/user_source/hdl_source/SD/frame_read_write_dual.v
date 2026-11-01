//=============================================================================
// frame_read_write_dual.v — 32bit 帧缓存：1 写 2 读（A/B 双通道）
//-----------------------------------------------------------------------------
// 功能：
//   在官方 1 写 1 读引擎基础上扩展出两个读通道，供 M2 的 A/B 交叉溶解和
//   滑动转场使用；写通道与官方版本完全一致（含 WRITE_V_FLIP）。
//
// 结构：
//   write_clk(100M)  sd_write_data → wfifo → frame_fifo_write → App_wr_*
//
//   mem_clk(125M)
//     frame_fifo_read_arb(A) --App_rd_en/Addr_A--\
//                                                >-- rd_arbiter --> SDRAM
//     frame_fifo_read_arb(B) --App_rd_en/Addr_B--/        |
//                                                         +--> Sdr_rd_en 路由
//     Sdr_rd_en --> rfifo_A --> read_data_a  (read_clk 25M，共用 read_en)
//               \-> rfifo_B --> read_data_b
//
// 时钟/复位：
//   mem_clk = 125MHz、write_clk = 100MHz、read_clk = 25MHz；rst 高有效。
//
// 接口：
//   SDRAM：App_rd_en/addr、Sdr_rd_en/dout、App_wr_en/addr/din/dm
//   读侧：read_req/ack/finish、read_base_a/b、read_len、read_en、
//         read_data_a/b[31:0]、read_empty_a/b、write_full、single_a
//   写侧：write_req/ack/finish、write_addr_0..3/index、write_len、
//         write_en、write_data[31:0]
//
// 参数：
//   BURST_SIZE=128、WRITE_V_FLIP=1、FRAME_WIDTH=640、FRAME_HEIGHT=480 等
//
// 内部例化：
//   wfifo_32_32_512      ×1（写侧）
//   frame_fifo_write     ×1（写 FSM）
//   frame_fifo_read_arb  ×2（A/B 读通道）
//   rd_arbiter           ×1（按突发仲裁）
//   rfifo_32_32_512      ×2（A/B 读 FIFO）
//
// 状态：⚠ 实验中（M1 止损，顶层未例化）
//   真实板上 A 通道仍有横带，即使数据由 M0 干净总线灌入也坏，问题压缩在
//   本模块的 FIFO/读通路内部；M2 前将按“交错帧布局”或“整行双 FIFO”重构。
//   在重新验收前不要把它接回顶层。
//=============================================================================
`timescale 1ns/1ps

module frame_read_write_dual
#
(
    parameter MEM_DATA_BITS          = 32,
    parameter READ_DATA_BITS         = 32,
    parameter WRITE_DATA_BITS        = 32,
    parameter ADDR_BITS              = 21,
    parameter BURST_BITS             = 9,
    parameter BURST_SIZE             = 128,
    parameter WRITE_V_FLIP           = 1,
    parameter FRAME_WIDTH            = 640,
    parameter FRAME_HEIGHT           = 480
)
(
    input                            rst,
    input                            mem_clk,
    input                            Sdr_init_done,
    input                            Sdr_init_ref_vld,
    input                            Sdr_busy,

    // SDRAM 用户接口（单套总线）
    output                           App_rd_en,
    output [ADDR_BITS - 1:0]         App_rd_addr,
    input                            Sdr_rd_en,
    input  [MEM_DATA_BITS - 1:0]     Sdr_rd_dout,

    // 读侧（视频 25MHz）
    input                            read_clk,
    input                            read_req,
    output                           read_req_ack,
    output                           read_finish,
    input  [ADDR_BITS - 1:0]         read_base_a,
    input  [ADDR_BITS - 1:0]         read_base_b,
    input  [ADDR_BITS - 1:0]         read_len,
    input                            read_en,
    output [READ_DATA_BITS - 1:0]    read_data_a,
    output [READ_DATA_BITS - 1:0]    read_data_b,
    output                           read_empty_a,
    output                           read_empty_b,
    output                           write_full,      // 写 FIFO 满（调试）
    input                            single_a,        // 调试：只让 A 通道占用读总线

    // 写侧（SD 100MHz）
    output                           App_wr_en,
    output [ADDR_BITS - 1:0]         App_wr_addr,
    output [MEM_DATA_BITS - 1:0]     App_wr_din,
    output [3:0]                     App_wr_dm,
    input                            write_clk,
    input                            write_req,
    output                           write_req_ack,
    output                           write_finish,
    input  [ADDR_BITS - 1:0]         write_addr_0,
    input  [ADDR_BITS - 1:0]         write_addr_1,
    input  [ADDR_BITS - 1:0]         write_addr_2,
    input  [ADDR_BITS - 1:0]         write_addr_3,
    input  [1:0]                     write_addr_index,
    input  [ADDR_BITS - 1:0]         write_len,
    input                            write_en,
    input  [WRITE_DATA_BITS - 1:0]   write_data
);

    wire [BURST_BITS - 1:0] rdusedw;
    wire [BURST_BITS - 1:0] rdusedw_a;
    wire [BURST_BITS - 1:0] rdusedw_b;

    wire App_rd_busy;
    wire App_wr_busy;

    wire write_fifo_aclr;

    wire O_wr_busy;
    wire O_rd_busy_a;
    wire O_rd_busy_b;

    wire [ADDR_BITS - 1:0] rd_addr_a;
    wire [ADDR_BITS - 1:0] rd_addr_b;
    wire rd_en_a;
    wire rd_en_b;
    wire rd_vld_a;
    wire rd_vld_b;

    wire fifo_aclr_a;
    wire fifo_aclr_b;

    wire req_a, req_b;
    wire done_a, done_b;
    wire grant;
    wire locked;
    wire grant_valid;

    // debug_single 来自 50MHz 域，先 2FF 同步到 mem_clk 再参与仲裁
    reg [1:0] single_sync;
    wire      single_a_s;
    always @(posedge mem_clk or posedge rst) begin
        if (rst)
            single_sync <= 2'b00;
        else
            single_sync <= {single_sync[0], single_a};
    end
    assign single_a_s = single_sync[1];

    wire ack_a, ack_b;
    wire fin_a, fin_b;

    assign App_wr_busy = O_wr_busy;
    assign App_rd_busy = O_rd_busy_a | O_rd_busy_b;
    assign App_wr_dm   = 4'b0000;

    // 两路必须都响应后才撤销 read_req：保证 A/B 在同一帧边界同时清 FIFO/复位地址。
    // （若某一路正在收尾上一帧的突发，它会晚几拍再 ack，另一路在 S_ACK 等待）
    assign read_req_ack = ack_a & ack_b;
    assign read_finish  = fin_a | fin_b;

    //-------------------------------------------------------------------------
    // 读突发仲裁
    //-------------------------------------------------------------------------
    rd_arbiter #(
        .DRAIN_CYCLES (8)
    ) u_rd_arb (
        .clk     (mem_clk),
        .rst     (rst),
        .req_a   (req_a),
        .req_b   (req_b & ~single_a_s),
        .busy_a  (O_rd_busy_a),
        .busy_b  (O_rd_busy_b),
        .level_a (rdusedw_a),
        .level_b (rdusedw_b),
        .grant   (grant),
        .locked  (locked),
        .grant_valid (grant_valid)
    );

    // SDRAM 只看到当前被授权通道的地址/使能；
    // K16 单通道调试时完全旁路仲裁器，让 A 走回 M0 的单读路径（用于硬件定位）。
    assign App_rd_en   = single_a_s ? rd_en_a :
                         (locked ? (grant ? rd_en_b : rd_en_a) : 1'b0);
    assign App_rd_addr = single_a_s ? rd_addr_a : (grant ? rd_addr_b : rd_addr_a);

    assign rd_vld_a = single_a_s ? Sdr_rd_en : (Sdr_rd_en & ~grant);
    assign rd_vld_b = single_a_s ? 1'b0      : (Sdr_rd_en &  grant);

    //-------------------------------------------------------------------------
    // 写通道：与官方单读版完全一致
    //-------------------------------------------------------------------------
    wfifo_32_32_512 write_buf
    (
        .clkr      (mem_clk),
        .clkw      (write_clk),
        .rst       (write_fifo_aclr | rst),
        .we        (write_en),
        .re        (App_wr_en),
        .di        (write_data),
        .empty_flag(),
        .full_flag (write_full),
        .wrusedw   (),
        .rdusedw   (rdusedw),
        .dout      (App_wr_din)
    );

    frame_fifo_write
    #
    (
        .MEM_DATA_BITS (MEM_DATA_BITS),
        .ADDR_BITS     (ADDR_BITS),
        .BURST_BITS    (BURST_BITS),
        .BURST_SIZE    (BURST_SIZE),
        .WRITE_V_FLIP  (WRITE_V_FLIP),
        .FRAME_WIDTH   (FRAME_WIDTH),
        .FRAME_HEIGHT  (FRAME_HEIGHT)
    )
    frame_fifo_write_m0
    (
        .rst             (rst),
        .mem_clk         (mem_clk),
        .Sdr_init_done   (Sdr_init_done),
        .Sdr_init_ref_vld(Sdr_init_ref_vld),
        .Sdr_busy        (Sdr_busy),
        .App_rd_busy     (App_rd_busy),
        .O_wr_busy       (O_wr_busy),
        .App_wr_en       (App_wr_en),
        .App_wr_addr     (App_wr_addr),
        .write_req       (write_req),
        .write_req_ack   (write_req_ack),
        .write_finish    (write_finish),
        .write_addr_0    (write_addr_0),
        .write_addr_1    (write_addr_1),
        .write_addr_2    (write_addr_2),
        .write_addr_3    (write_addr_3),
        .write_addr_index(write_addr_index),
        .write_len       (write_len),
        .fifo_aclr       (write_fifo_aclr),
        .rdusedw         (rdusedw),
        .App_wr_sop      (1'b0)       // 旧版无行首标志
    );

    //-------------------------------------------------------------------------
    // 读通道 A
    //-------------------------------------------------------------------------
    frame_fifo_read_arb
    #
    (
        .MEM_DATA_BITS (MEM_DATA_BITS),
        .ADDR_BITS     (ADDR_BITS),
        .BURST_BITS    (BURST_BITS),
        .BURST_SIZE    (BURST_SIZE)
    )
    frame_fifo_read_a
    (
        .rst             (rst),
        .mem_clk         (mem_clk),
        .Sdr_init_done   (Sdr_init_done),
        .Sdr_init_ref_vld(Sdr_init_ref_vld),
        .Sdr_busy        (Sdr_busy),
        .App_wr_busy     (App_wr_busy),
        .O_rd_busy       (O_rd_busy_a),
        .burst_req       (req_a),
        .burst_grant     (grant_valid && ~grant),
        .burst_done      (done_a),
        .App_rd_en       (rd_en_a),
        .App_rd_addr     (rd_addr_a),
        .read_req        (read_req),
        .read_req_ack    (ack_a),
        .read_finish     (fin_a),
        .read_base_addr  (read_base_a),
        .read_len        (read_len),
        .fifo_aclr       (fifo_aclr_a),
        .wrusedw         (rdusedw_a),
        .rx_valid        (rd_vld_a)
    );

    //-------------------------------------------------------------------------
    // 读通道 B
    //-------------------------------------------------------------------------
    frame_fifo_read_arb
    #
    (
        .MEM_DATA_BITS (MEM_DATA_BITS),
        .ADDR_BITS     (ADDR_BITS),
        .BURST_BITS    (BURST_BITS),
        .BURST_SIZE    (BURST_SIZE)
    )
    frame_fifo_read_b
    (
        .rst             (rst),
        .mem_clk         (mem_clk),
        .Sdr_init_done   (Sdr_init_done),
        .Sdr_init_ref_vld(Sdr_init_ref_vld),
        .Sdr_busy        (Sdr_busy),
        .App_wr_busy     (App_wr_busy),
        .O_rd_busy       (O_rd_busy_b),
        .burst_req       (req_b),
        .burst_grant     (grant_valid && grant),
        .burst_done      (done_b),
        .App_rd_en       (rd_en_b),
        .App_rd_addr     (rd_addr_b),
        .read_req        (read_req),
        .read_req_ack    (ack_b),
        .read_finish     (fin_b),
        .read_base_addr  (read_base_b),
        .read_len        (read_len),
        .fifo_aclr       (fifo_aclr_b),
        .wrusedw         (rdusedw_b),
        .rx_valid        (rd_vld_b)
    );

    //-------------------------------------------------------------------------
    // 读数据 FIFO（A/B 各一套，共用 read_en 保证锁步）
    //-------------------------------------------------------------------------
    rfifo_32_32_512 read_buf_a
    (
        .clkr      (read_clk),
        .clkw      (mem_clk),
        .rst       (fifo_aclr_a | rst),
        .we        (rd_vld_a),
        .re        (read_en),
        .di        (Sdr_rd_dout),
        .empty_flag(read_empty_a),
        .full_flag (),
        .wrusedw   (rdusedw_a),
        .rdusedw   (),
        .dout      (read_data_a)
    );

    rfifo_32_32_512 read_buf_b
    (
        .clkr      (read_clk),
        .clkw      (mem_clk),
        .rst       (fifo_aclr_b | rst),
        .we        (rd_vld_b),
        .re        (read_en),
        .di        (Sdr_rd_dout),
        .empty_flag(read_empty_b),
        .full_flag (),
        .wrusedw   (rdusedw_b),
        .rdusedw   (),
        .dout      (read_data_b)
    );

endmodule
