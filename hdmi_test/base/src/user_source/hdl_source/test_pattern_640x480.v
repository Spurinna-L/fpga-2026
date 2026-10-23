//=============================================================================
// test_pattern_640x480.v — 无图时的彩条回退（诊断用）
//-----------------------------------------------------------------------------
// 对齐 video_delay 之后的 de/vs（负极性同步：vs 低有效）
// 输出 8 条竖彩条 + 白色边框，用于判断：
//   有彩条 = HDMI/PHY/显示器链路正常，问题在 SD/BMP
//   无彩条 = HDMI/PHY/显示器链路本身有问题
//=============================================================================
`timescale 1ns / 1ps

module test_pattern_640x480(
    input  wire        clk,
    input  wire        rst,
    input  wire        vs,      // 负极性（低有效）
    input  wire        de,
    output reg  [23:0] rgb
);

    reg [10:0] x;
    reg [10:0] y;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x <= 11'd0;
            y <= 11'd0;
        end else begin
            if (!de)
                x <= 11'd0;
            else if (x == 11'd639)
                x <= 11'd0;
            else
                x <= x + 1'b1;

            if (!vs)
                y <= 11'd0;
            else if (de && x == 11'd639)
                y <= (y == 11'd479) ? 11'd0 : y + 1'b1;
        end
    end

    wire [2:0] bar = (x < 11'd80)  ? 3'd0 :
                     (x < 11'd160) ? 3'd1 :
                     (x < 11'd240) ? 3'd2 :
                     (x < 11'd320) ? 3'd3 :
                     (x < 11'd400) ? 3'd4 :
                     (x < 11'd480) ? 3'd5 :
                     (x < 11'd560) ? 3'd6 : 3'd7;

    always @(*) begin
        case (bar)
            3'd0: rgb = 24'hFFFFFF; // white
            3'd1: rgb = 24'hFFFF00; // yellow
            3'd2: rgb = 24'h00FFFF; // cyan
            3'd3: rgb = 24'h00FF00; // green
            3'd4: rgb = 24'hFF00FF; // magenta
            3'd5: rgb = 24'hFF0000; // red
            3'd6: rgb = 24'h0000FF; // blue
            default: rgb = 24'h000000; // black
        endcase

        // 白色边框（便于确认整幅画面位置）
        if (y < 11'd20 || y > 11'd459 || x < 11'd20 || x > 11'd619)
            rgb = 24'hFFFFFF;
    end

endmodule
