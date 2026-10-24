//=============================================================================
// seg_led.v  —  4 位七段数码管动态扫描显示
//-----------------------------------------------------------------------------
// 复用：rtl/reuse/misc/seg_led_decoder.v（段码）+ seg_sel_decoder.v（位选）。
// 用途：显示媒体序号 / 状态码（演示脚本：SD 卡媒体列表序号）。
// 引脚：seg_sel[3:0]=C9,B6,A5,A3；seg_led[7:0]=A4,A6,B8,E8,A7,B5,A8,C8。
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
