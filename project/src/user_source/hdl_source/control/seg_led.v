//=============================================================================
// seg_led.v — 4 位七段数码管动态扫描显示
//-----------------------------------------------------------------------------
// 功能：
//   把 value[15:0] 的 4 个 nibble 轮流送到段码译码器，同时输出对应的位选，
//   利用人眼视觉暂留形成 4 位同时显示；每 50000 个 clk 换一位（约 1kHz 刷新）。
//
// 时钟/复位：clk = 50MHz；rst_n 低有效。
//
// 接口：
//   in  value[31:0]  显示值（实际只用低 16bit，每 4bit 一个十六进制数字）
//   in  dot[3:0]     各位小数点使能
//   out seg_sel[3:0] 位选（低有效）
//   out seg_led[7:0] 段码（[7]=小数点，[6:0]=a..g）
//
// 参数：无（扫描分频固定 50000）
//
// 内部例化：
//   seg_led_decoder   4bit → 7 段段码
//   seg_sel_decoder   2bit 位索引 → 4 位位选
//
// 备注：
//   顶层 dot 接 4'b0000，当前不点亮小数点。
//=============================================================================
`timescale 1ns / 1ps

module seg_led (
    input  wire        clk,         // 系统 50MHz
    input  wire        rst_n,
    input  wire [31:0] value,       // 4 个数码管要显示的值（每 8bit 一个 BCD/HEX 数字）
    input  wire [3:0]  dot,         // 各位小数点使能
    output wire [3:0]  seg_sel,
    output wire [7:0]  seg_led
);

    // 扫描分频：约 1kHz 刷新（50MHz / 50000）
    reg [15:0] scan_cnt;
    reg [1:0]  bit_disp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_cnt <= 16'd0;
            bit_disp <= 2'd0;
        end else if (scan_cnt == 16'd49999) begin
            scan_cnt <= 16'd0;
            bit_disp <= bit_disp + 1'b1;
        end else begin
            scan_cnt <= scan_cnt + 1'b1;
        end
    end

    // 选择当前位的 nibble（value[7:0] 为最低位）
    reg [3:0] cur_digit;
    always @(*) begin
        case (bit_disp)
            2'd0: cur_digit = value[3:0];
            2'd1: cur_digit = value[7:4];
            2'd2: cur_digit = value[11:8];
            default: cur_digit = value[15:12];
        endcase
    end

    wire [7:0] seg_led_dec;
    seg_led_decoder u_led_dec (
        .data_disp (cur_digit),
        .dot_ena   (dot[bit_disp]),
        .seg_led   (seg_led_dec)
    );

    seg_sel_decoder u_sel_dec (
        .bit_disp (bit_disp),
        .seg_sel  (seg_sel)
    );

    assign seg_led = seg_led_dec;

endmodule
