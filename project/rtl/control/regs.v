//=============================================================================
// regs.v  —  控制寄存器组（无 CPU）
//-----------------------------------------------------------------------------
// 系统采用"寄存器映射"代替处理器：键盘/拨码通过写端口更新寄存器，各功能模块
// 只读自己关心的字段。所有跨模块控制量集中在此，便于调试与 OSD 回显。
//
// 地址映射（wr_addr）：
//   0x00 BRIGHTNESS      [7:0]  亮度偏移（有符号）
//   0x01 CONTRAST        [7:0]  对比度增益 128=1.0
//   0x02 SATURATION      [7:0]  饱和度增益 128=1.0
//   0x03 TRANSITION_TYPE [1:0]  转场类型
//   0x04 AUDIO_VOLUME    [7:0]  音量
//   0x05 MEDIA_INDEX     [7:0]  当前媒体序号
//   0x06 DISPLAY_MODE    [2:0]  显示模式（正常/测试图/自检）
//   0x07 CTRL            [0]=osd_en [2]=auto_play（bit1 保留）
//=============================================================================
`timescale 1ns / 1ps

module regs (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        wr_en,
    input  wire [7:0]  wr_addr,
    input  wire [31:0] wr_data,

    output reg  [7:0]  brightness,
    output reg  [7:0]  contrast,
    output reg  [7:0]  saturation,
    output reg  [1:0]  transition_type,
    output reg  [7:0]  audio_volume,
    output reg  [7:0]  media_index,
    output reg  [2:0]  display_mode,
    output reg         osd_en,
    output reg         auto_play
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            brightness     <= 8'd0;
            contrast       <= 8'd128;
            saturation     <= 8'd128;
            transition_type<= 2'd0;
            audio_volume   <= 8'd128;
            media_index    <= 8'd0;
            display_mode   <= 3'd0;
            osd_en         <= 1'b1;
            auto_play      <= 1'b1;
        end else if (wr_en) begin
            case (wr_addr)
                8'h00: brightness      <= wr_data[7:0];
                8'h01: contrast        <= wr_data[7:0];
                8'h02: saturation      <= wr_data[7:0];
                8'h03: transition_type <= wr_data[1:0];
                8'h04: audio_volume    <= wr_data[7:0];
                8'h05: media_index     <= wr_data[7:0];
                8'h06: display_mode    <= wr_data[2:0];
                8'h07: begin
                    osd_en         <= wr_data[0];
                    auto_play      <= wr_data[2];
                end
                default: ;
            endcase
        end
    end

endmodule
