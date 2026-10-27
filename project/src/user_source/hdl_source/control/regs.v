//=============================================================================
// regs.v — 16 键事件译码、参数寄存器、1Hz 时间戳与数码管显示值
//-----------------------------------------------------------------------------
// 功能：
//   1) 对 key_deb 做上升沿检测，产生单拍 key_press[15:0]；
//   2) 按键译码成亮度/对比度/转场/OSD/音源/可视化/音色等参数寄存器；
//   3) 50MHz 分频出 1Hz tick，维护 MM:SS 时间戳；
//   4) 把 SD 状态码、图片号、参数拼成 4 位数码管显示值；
//   5) 把 100MHz 域的 state_code/img_idx 2FF 同步到 50MHz。
//
// 时钟/复位：clk = 50MHz；rst_n 低有效。
//
// 接口：
//   in  key_deb[15:0]        消抖后键值（按下 = 1）
//   in  state_code[3:0]      SD/BMP 状态（100MHz 域，慢变量，2FF）
//   in  img_idx[1:0]         当前图片序号（100MHz 域，2FF）
//   in  disp_buf_idx[1:0]    当前显示缓冲
//   out brightness/contrast  亮度（-64..+64）/ 对比度（64..192）
//   out trans_mode/osd_en    转场模式 / OSD 开关
//   out subtitle_en          底部滚动字幕开关（K13）
//   out audio_src/timbre     音源 L1/L2、L2 音色
//   out viz_mode             可视化模式 0..3
//   out time_mm/time_ss/tick_1hz  时间戳与 1Hz 脉冲
//   out seg_value[31:0]      数码管显示值（4 位 × 4bit）
//   out key_press[15:0]      单拍按下脉冲
//   out debug_single/probe_m0  K16/K15 调试标志（当前顶层无消费者）
//
// 参数：
//   SEC_CYCLES = 26'd49_999_999   50MHz 下 1 秒
//
// 按键分配（与《接口对接表》I7 一致）：
//   [0] 下一张 / [1] 自动轮播（直接送 sd_card_bmp，本模块只旁路）
//   [2] 转场模式  [3] OSD 开关  [4]/[5] 亮度 +/-8
//   [6]/[7] 对比度 +/-16  [8] 音源  [9] 音色  [10] 可视化
//   [11] 参数一键复位  [12] 底部滚动字幕开关
//   [14] probe_m0  [15] debug_single
//
// 数码管 4 位（高位在左）：
//   [15:12] SD 状态码  [11:8] 图片序号  [7:4] 转场/OSD  [3:0] 音源/可视化
//
// 内部例化：无
//=============================================================================
`timescale 1ns/1ps

module regs
#(
    parameter [25:0] SEC_CYCLES = 26'd49_999_999   // 50MHz 下 1 秒
)
(
    input  wire        clk,            // 50MHz
    input  wire        rst_n,          // 低有效
    input  wire [15:0] key_deb,        // 按下为 1（key_filter 输出）

    input  wire [3:0]  state_code,     // 来自 sd_card_bmp（100MHz 域，慢变量）
    input  wire [1:0]  img_idx,        // 来自 sd_card_bmp
    input  wire [1:0]  disp_buf_idx,   // 当前显示缓冲

    output reg signed [7:0] brightness, // 默认 0，范围 -64..+64（M2 video_proc 用）
    output reg  [7:0]  contrast,        // 默认 128，范围 64..192
    output reg  [1:0]  trans_mode,     // 0=溶解 1=滑动 2=直切
    output reg         osd_en,
    output reg         subtitle_en,    // 底部滚动字幕开关（K13）
    output reg  [1:0]  audio_src,      // 0=L1 1=L2
    output reg  [1:0]  viz_mode,       // 0=关 1=声波 2=频谱 3=声波+频谱
    output reg  [1:0]  timbre,
    output reg         debug_single,   // K16：单通道调试（只读/只显示 A）
    output reg         probe_m0,       // K15：切换到 M0 原始单读引擎（硬件对比）

    output reg  [7:0]  time_mm,        // 00..99
    output reg  [7:0]  time_ss,        // 00..59
    output reg         tick_1hz,
    output wire [31:0] seg_value,      // 4 位数码管显示值
    output wire [15:0] key_press       // 单拍按下脉冲（给后续模块用）
);

    //-------------------------------------------------------------------------
    // 50MHz -> 1Hz
    //-------------------------------------------------------------------------
    reg [25:0] sec_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sec_cnt  <= 26'd0;
            tick_1hz <= 1'b0;
        end else if (sec_cnt == SEC_CYCLES) begin
            sec_cnt  <= 26'd0;
            tick_1hz <= 1'b1;
        end else begin
            sec_cnt  <= sec_cnt + 26'd1;
            tick_1hz <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            time_mm <= 8'd0;
            time_ss <= 8'd0;
        end else if (tick_1hz) begin
            if (time_ss == 8'd59) begin
                time_ss <= 8'd0;
                time_mm <= (time_mm == 8'd99) ? 8'd0 : (time_mm + 8'd1);
            end else begin
                time_ss <= time_ss + 8'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 按键上升沿
    //-------------------------------------------------------------------------
    reg [15:0] key_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_prev <= 16'd0;
        else
            key_prev <= key_deb;
    end

    assign key_press = key_deb & ~key_prev;

    //-------------------------------------------------------------------------
    // 参数寄存器
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            brightness <= 8'sd0;
            contrast   <= 8'd128;
            trans_mode <= 2'd0;
            osd_en     <= 1'b1;
            subtitle_en <= 1'b1;
            audio_src  <= 2'd0;
            viz_mode   <= 2'd3;
            timbre     <= 2'd0;
            debug_single <= 1'b0;
            probe_m0     <= 1'b1;      // 默认使用 M0 单读引擎（稳定通路）
        end else begin
            if (key_press[11]) begin
                brightness <= 8'sd0;
                contrast   <= 8'd128;
                trans_mode <= 2'd0;
                osd_en     <= 1'b1;
                subtitle_en <= 1'b1;
                audio_src  <= 2'd0;
                viz_mode   <= 2'd3;
                timbre     <= 2'd0;
                debug_single <= 1'b0;
                probe_m0     <= 1'b1;
            end else begin
                if (key_press[2])
                    trans_mode <= (trans_mode == 2'd2) ? 2'd0 : (trans_mode + 2'd1);
                if (key_press[3])
                    osd_en <= ~osd_en;
                if (key_press[12])
                    subtitle_en <= ~subtitle_en;
                if (key_press[4])
                    brightness <= (brightness >= 8'sd64) ? 8'sd64 : (brightness + 8'sd8);
                if (key_press[5])
                    brightness <= (brightness <= -8'sd64) ? -8'sd64 : (brightness - 8'sd8);
                if (key_press[6])
                    contrast <= (contrast >= 8'd192) ? 8'd192 : (contrast + 8'd16);
                if (key_press[7])
                    contrast <= (contrast <= 8'd64) ? 8'd64 : (contrast - 8'd16);
                if (key_press[8])
                    audio_src <= (audio_src == 2'd0) ? 2'd1 : 2'd0;
                if (key_press[9])
                    timbre <= (timbre == 2'd2) ? 2'd0 : (timbre + 2'd1);
                if (key_press[10])
                    viz_mode <= viz_mode + 2'd1;
                if (key_press[15])
                    debug_single <= ~debug_single;
                if (key_press[14])
                    probe_m0 <= ~probe_m0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 100MHz 慢变量 -> 50MHz（2FF）
    //-------------------------------------------------------------------------
    reg [3:0] state_s0, state_s1;
    reg [1:0] img_s0, img_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_s0 <= 4'd0;
            state_s1 <= 4'd0;
            img_s0   <= 2'd0;
            img_s1   <= 2'd0;
        end else begin
            state_s0 <= state_code;
            state_s1 <= state_s0;
            img_s0   <= img_idx;
            img_s1   <= img_s0;
        end
    end

    //-------------------------------------------------------------------------
    // 数码管显示值
    //-------------------------------------------------------------------------
    assign seg_value = {
        16'h0000,
        state_s1,                       // [15:12] SD 状态
        2'b00, img_s1,                  // [11:8]  图片序号
        1'b0, trans_mode, osd_en,       // [7:4]   转场 / OSD
        audio_src[0], viz_mode, 1'b0    // [3:0]   音源 / 可视化
    };

endmodule
