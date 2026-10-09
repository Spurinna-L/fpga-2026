//=============================================================================
// mic_adc.v  —  麦克风采集（复用官方 spi_rx + 12bit SPI ADC）
//-----------------------------------------------------------------------------
// 复用：rtl/reuse/misc/spi_rx.v（16bit 串行接收，内部产生 SCK/CS 时序）。
// 引脚：CS=J6, MISO=K5, SCK=H3, RST=G6；ADC 采样率 ≤100kSPS。
//
// 时钟：spi_rx 需要一个 clk_baud（其内部据此产生 SCK）。本模块在 clk 域内
//       分频得到 clk_baud（默认 clk/8），确保 SCK 满足 ADC 时序。
// 输出：16bit 右对齐采样 + sample_valid（每帧结束脉冲）。
//
// 【当前状态】基本打通（可直接用于第 4 周麦克风频谱）；采样率/位对齐在集成时校准。
//=============================================================================
`timescale 1ns / 1ps

module mic_adc #(
    parameter DIV = 8           // clk_baud = clk / DIV
)(
    input  wire        clk,     // 系统 50MHz
    input  wire        rst_n,

    // 物理接口
    output wire        adc_cs,      // J6
    input  wire        adc_miso,    // K5
    output wire        adc_sck,     // H3
    output wire        adc_rst_n,   // G6

    // 采样输出
    output wire [15:0] sample,
    output wire        sample_valid
);

    assign adc_rst_n = rst_n;

    // clk_baud 分频
    reg [$clog2(DIV)-1:0] div_cnt;
    reg clk_baud;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt  <= 0;
            clk_baud <= 1'b0;
        end else if (div_cnt == DIV/2 - 1) begin
            div_cnt  <= 0;
            clk_baud <= ~clk_baud;
        end else begin
            div_cnt  <= div_cnt + 1'b1;
        end
    end

    wire [15:0] data_out;
    wire        sck_i, cs_i;

    spi_rx u_spi_rx (
        .clk_baud (clk_baud),
        .sck      (sck_i),
        .cs       (cs_i),
        .miso     (adc_miso),
        .rst_n    (rst_n),
        .data_out (data_out)
    );

    assign adc_sck = sck_i;
    assign adc_cs  = cs_i;
    assign sample  = data_out;

    // sample_valid：CS 上升沿（一帧接收完成）
    reg cs_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cs_d <= 1'b0;
        else        cs_d <= cs_i;
    end
    assign sample_valid = cs_i & ~cs_d;

endmodule
