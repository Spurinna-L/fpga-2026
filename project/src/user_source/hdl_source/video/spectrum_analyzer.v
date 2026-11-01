//=============================================================================
// spectrum_analyzer.v — 8 段频谱能量提取（平滑 + 峰值保持 + 自动增益）
//-----------------------------------------------------------------------------
// 功能：
//   对 48kHz 音频样本做 9 个并联低通（系数为 2 的幂之和，无需乘法器），
//   每个低通由 3 级一阶级联而成（裙边 -60dB/dec，频段间串扰小），
//   相邻低通的差值就是一条带通，正好切出 8 个频段：
//
//     段号    0      1      2      3      4      5      6      7
//     上限  179Hz  269Hz  388Hz  597Hz  836Hz 1224Hz 1790Hz 2596Hz
//     下限  119Hz  179Hz  269Hz  388Hz  597Hz  836Hz 1224Hz 1790Hz
//
//   每个帧边界（vs 下降沿）把 8 个频段累加值换算成 0..48 的柱高，做：
//     · 一阶平滑   bar <= (bar*3 + tgt) >> 2      （缓升缓降，便于观看）
//     · 峰值保持   peak 取历史最大值，之后每 2 帧降 1px
//     · 自动增益   max(tgt) 长期偏低就减小衰减量、偏高就加大，
//                  保证 I2S 直连（L1 音阶 ±2e6）与合成器（L2，幅度较小）
//                  两种音源都能撑满柱子高度。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效。
//
// 接口：
//   in  I_vs_fall      帧结束脉冲（单拍）
//   in  I_samp_valid   48kHz 样本有效（单拍）
//   in  I_samp[23:0]   有符号 24bit PCM
//   out O_bar[47:0]    8 段柱高，每段 6bit（O_bar[6*k +: 6]）
//   out O_peak[47:0]   8 段峰值，每段 6bit
//
// 参数：无
//
// 内部例化：无
//
// 备注：
//   单级一阶低通的截止频率 fc = k * fs / (256 * 2*pi) = k * 29.84Hz，
//   所以 k = 4,6,9,13,20,28,41,60,87 恰好铺满 119Hz ~ 2596Hz；级联 3 级后
//   等效截止频率略降（约 -3dB 点不变，过渡带更陡），分段仍按上面的表看。
//   换算成移位加法：例如 k=13 → (d>>5) + (d>>6) + (d>>8)，无乘法器。
//   全模块不使用数组与 for 循环，避免综合器对数组端口/变量下标推断不佳。
//=============================================================================
`timescale 1ns / 1ps

module spectrum_analyzer (
    input  wire               I_clk,
    input  wire               I_rst,
    input  wire               I_vs_fall,
    input  wire               I_samp_valid,
    input  wire signed [23:0] I_samp,
    output wire [47:0]        O_bar,
    output wire [47:0]        O_peak
);

    localparam [5:0] BAR_MAX = 6'd48;

    // 3 级级联一阶低通（每级 9 路，系数同为 2 的幂和，无乘法器）：
    // 单级一阶的裙边只有 -20dB/dec，相邻段互相渗透严重，8 根柱子会"一起起伏"；
    // 级联 3 级后裙边 -60dB/dec，频段间选择性明显变好，柱形才会随音高移动。
    reg  signed [17:0] a0, a1, a2, a3, a4, a5, a6, a7, a8;   // 第 1 级
    reg  signed [17:0] b0, b1, b2, b3, b4, b5, b6, b7, b8;   // 第 2 级
    reg  signed [17:0] c0, c1, c2, c3, c4, c5, c6, c7, c8;   // 第 3 级

    wire signed [17:0] x18 = {{2{I_samp[23]}}, I_samp[23:8]};

    // 各级的"输入 - 状态"差值（第 1 级输入是样本，第 2 级是 a，第 3 级是 b）
    // 第 1 级
    wire signed [17:0] da0 = x18 - a0;
    wire signed [17:0] da1 = x18 - a1;
    wire signed [17:0] da2 = x18 - a2;
    wire signed [17:0] da3 = x18 - a3;
    wire signed [17:0] da4 = x18 - a4;
    wire signed [17:0] da5 = x18 - a5;
    wire signed [17:0] da6 = x18 - a6;
    wire signed [17:0] da7 = x18 - a7;
    wire signed [17:0] da8 = x18 - a8;

    // 第 2 级
    wire signed [17:0] db0 = a0 - b0;
    wire signed [17:0] db1 = a1 - b1;
    wire signed [17:0] db2 = a2 - b2;
    wire signed [17:0] db3 = a3 - b3;
    wire signed [17:0] db4 = a4 - b4;
    wire signed [17:0] db5 = a5 - b5;
    wire signed [17:0] db6 = a6 - b6;
    wire signed [17:0] db7 = a7 - b7;
    wire signed [17:0] db8 = a8 - b8;

    // 第 3 级
    wire signed [17:0] dc0 = b0 - c0;
    wire signed [17:0] dc1 = b1 - c1;
    wire signed [17:0] dc2 = b2 - c2;
    wire signed [17:0] dc3 = b3 - c3;
    wire signed [17:0] dc4 = b4 - c4;
    wire signed [17:0] dc5 = b5 - c5;
    wire signed [17:0] dc6 = b6 - c6;
    wire signed [17:0] dc7 = b7 - c7;
    wire signed [17:0] dc8 = b8 - c8;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            a0 <= 18'sd0; a1 <= 18'sd0; a2 <= 18'sd0;
            a3 <= 18'sd0; a4 <= 18'sd0; a5 <= 18'sd0;
            a6 <= 18'sd0; a7 <= 18'sd0; a8 <= 18'sd0;
            b0 <= 18'sd0; b1 <= 18'sd0; b2 <= 18'sd0;
            b3 <= 18'sd0; b4 <= 18'sd0; b5 <= 18'sd0;
            b6 <= 18'sd0; b7 <= 18'sd0; b8 <= 18'sd0;
            c0 <= 18'sd0; c1 <= 18'sd0; c2 <= 18'sd0;
            c3 <= 18'sd0; c4 <= 18'sd0; c5 <= 18'sd0;
            c6 <= 18'sd0; c7 <= 18'sd0; c8 <= 18'sd0;
        end
        else if (I_samp_valid) begin
            a0 <= a0 + (da0 >>> 6);                                 // fc=119Hz
            a1 <= a1 + (da1 >>> 6) + (da1 >>> 7);                   // fc=179Hz
            a2 <= a2 + (da2 >>> 5) + (da2 >>> 8);                   // fc=269Hz
            a3 <= a3 + (da3 >>> 5) + (da3 >>> 6) + (da3 >>> 8);     // fc=388Hz
            a4 <= a4 + (da4 >>> 4) + (da4 >>> 6);                   // fc=597Hz
            a5 <= a5 + (da5 >>> 4) + (da5 >>> 5) + (da5 >>> 6);     // fc=836Hz
            a6 <= a6 + (da6 >>> 3) + (da6 >>> 5) + (da6 >>> 8);     // fc=1224Hz
            a7 <= a7 + (da7 >>> 3) + (da7 >>> 4) + (da7 >>> 5) + (da7 >>> 6); // fc=1790Hz
            a8 <= a8 + (da8 >>> 2) + (da8 >>> 4) + (da8 >>> 6) + (da8 >>> 7) + (da8 >>> 8); // fc=2596Hz

            b0 <= b0 + (db0 >>> 6);                                 // fc=119Hz
            b1 <= b1 + (db1 >>> 6) + (db1 >>> 7);                   // fc=179Hz
            b2 <= b2 + (db2 >>> 5) + (db2 >>> 8);                   // fc=269Hz
            b3 <= b3 + (db3 >>> 5) + (db3 >>> 6) + (db3 >>> 8);     // fc=388Hz
            b4 <= b4 + (db4 >>> 4) + (db4 >>> 6);                   // fc=597Hz
            b5 <= b5 + (db5 >>> 4) + (db5 >>> 5) + (db5 >>> 6);     // fc=836Hz
            b6 <= b6 + (db6 >>> 3) + (db6 >>> 5) + (db6 >>> 8);     // fc=1224Hz
            b7 <= b7 + (db7 >>> 3) + (db7 >>> 4) + (db7 >>> 5) + (db7 >>> 6); // fc=1790Hz
            b8 <= b8 + (db8 >>> 2) + (db8 >>> 4) + (db8 >>> 6) + (db8 >>> 7) + (db8 >>> 8); // fc=2596Hz

            c0 <= c0 + (dc0 >>> 6);                                 // fc=119Hz
            c1 <= c1 + (dc1 >>> 6) + (dc1 >>> 7);                   // fc=179Hz
            c2 <= c2 + (dc2 >>> 5) + (dc2 >>> 8);                   // fc=269Hz
            c3 <= c3 + (dc3 >>> 5) + (dc3 >>> 6) + (dc3 >>> 8);     // fc=388Hz
            c4 <= c4 + (dc4 >>> 4) + (dc4 >>> 6);                   // fc=597Hz
            c5 <= c5 + (dc5 >>> 4) + (dc5 >>> 5) + (dc5 >>> 6);     // fc=836Hz
            c6 <= c6 + (dc6 >>> 3) + (dc6 >>> 5) + (dc6 >>> 8);     // fc=1224Hz
            c7 <= c7 + (dc7 >>> 3) + (dc7 >>> 4) + (dc7 >>> 5) + (dc7 >>> 6); // fc=1790Hz
            c8 <= c8 + (dc8 >>> 2) + (dc8 >>> 4) + (dc8 >>> 6) + (dc8 >>> 7) + (dc8 >>> 8); // fc=2596Hz
        end
    end

    //-------------------------------------------------------------------------
    // 相邻低通相减 = 带通（取第 3 级输出）；绝对值后降 4bit（>>4）压缩动态范围
    //-------------------------------------------------------------------------
    wire signed [17:0] band0 = c1 - c0;
    wire signed [17:0] band1 = c2 - c1;
    wire signed [17:0] band2 = c3 - c2;
    wire signed [17:0] band3 = c4 - c3;
    wire signed [17:0] band4 = c5 - c4;
    wire signed [17:0] band5 = c6 - c5;
    wire signed [17:0] band6 = c7 - c6;
    wire signed [17:0] band7 = c8 - c7;

    wire [17:0] abs0 = band0[17] ? (-band0) : band0;
    wire [17:0] abs1 = band1[17] ? (-band1) : band1;
    wire [17:0] abs2 = band2[17] ? (-band2) : band2;
    wire [17:0] abs3 = band3[17] ? (-band3) : band3;
    wire [17:0] abs4 = band4[17] ? (-band4) : band4;
    wire [17:0] abs5 = band5[17] ? (-band5) : band5;
    wire [17:0] abs6 = band6[17] ? (-band6) : band6;
    wire [17:0] abs7 = band7[17] ? (-band7) : band7;

    wire [13:0] mag0 = abs0[17:4];
    wire [13:0] mag1 = abs1[17:4];
    wire [13:0] mag2 = abs2[17:4];
    wire [13:0] mag3 = abs3[17:4];
    wire [13:0] mag4 = abs4[17:4];
    wire [13:0] mag5 = abs5[17:4];
    wire [13:0] mag6 = abs6[17:4];
    wire [13:0] mag7 = abs7[17:4];

    //-------------------------------------------------------------------------
    // 帧内累加器
    //-------------------------------------------------------------------------
    reg [23:0] acc0, acc1, acc2, acc3, acc4, acc5, acc6, acc7;

    reg  [3:0] attn;       // 全局衰减量（自动增益），值越大柱越矮

    wire [14:0] en0 = acc0[23:9];
    wire [14:0] en1 = acc1[23:9];
    wire [14:0] en2 = acc2[23:9];
    wire [14:0] en3 = acc3[23:9];
    wire [14:0] en4 = acc4[23:9];
    wire [14:0] en5 = acc5[23:9];
    wire [14:0] en6 = acc6[23:9];
    wire [14:0] en7 = acc7[23:9];

    wire [14:0] sc0 = en0 >> attn;
    wire [14:0] sc1 = en1 >> attn;
    wire [14:0] sc2 = en2 >> attn;
    wire [14:0] sc3 = en3 >> attn;
    wire [14:0] sc4 = en4 >> attn;
    wire [14:0] sc5 = en5 >> attn;
    wire [14:0] sc6 = en6 >> attn;
    wire [14:0] sc7 = en7 >> attn;

    wire [5:0] g0 = (sc0 > {9'd0, BAR_MAX}) ? BAR_MAX : sc0[5:0];
    wire [5:0] g1 = (sc1 > {9'd0, BAR_MAX}) ? BAR_MAX : sc1[5:0];
    wire [5:0] g2 = (sc2 > {9'd0, BAR_MAX}) ? BAR_MAX : sc2[5:0];
    wire [5:0] g3 = (sc3 > {9'd0, BAR_MAX}) ? BAR_MAX : sc3[5:0];
    wire [5:0] g4 = (sc4 > {9'd0, BAR_MAX}) ? BAR_MAX : sc4[5:0];
    wire [5:0] g5 = (sc5 > {9'd0, BAR_MAX}) ? BAR_MAX : sc5[5:0];
    wire [5:0] g6 = (sc6 > {9'd0, BAR_MAX}) ? BAR_MAX : sc6[5:0];
    wire [5:0] g7 = (sc7 > {9'd0, BAR_MAX}) ? BAR_MAX : sc7[5:0];

    // 本帧最大目标柱高（自动增益用）
    wire [5:0] m01 = (g1 > g0) ? g1 : g0;
    wire [5:0] m23 = (g3 > g2) ? g3 : g2;
    wire [5:0] m45 = (g5 > g4) ? g5 : g4;
    wire [5:0] m67 = (g7 > g6) ? g7 : g6;
    wire [5:0] m03 = (m23 > m01) ? m23 : m01;
    wire [5:0] m47 = (m67 > m45) ? m67 : m45;
    wire [5:0] gmax = (m47 > m03) ? m47 : m03;

    //-------------------------------------------------------------------------
    // 柱高 / 峰值寄存器
    //-------------------------------------------------------------------------
    reg [5:0] bar0, bar1, bar2, bar3, bar4, bar5, bar6, bar7;
    reg [5:0] pk0,  pk1,  pk2,  pk3,  pk4,  pk5,  pk6,  pk7;
    reg       pk_tog;      // 峰值每 2 帧降 1px

    // 一阶平滑：(bar*3 + tgt + 2) >> 2 → bar*4 - bar，避免乘法器
    wire [7:0] sm0 = (({2'b00, bar0} << 2) - {2'b00, bar0} + {2'b00, g0} + 8'd2) >> 2;
    wire [7:0] sm1 = (({2'b00, bar1} << 2) - {2'b00, bar1} + {2'b00, g1} + 8'd2) >> 2;
    wire [7:0] sm2 = (({2'b00, bar2} << 2) - {2'b00, bar2} + {2'b00, g2} + 8'd2) >> 2;
    wire [7:0] sm3 = (({2'b00, bar3} << 2) - {2'b00, bar3} + {2'b00, g3} + 8'd2) >> 2;
    wire [7:0] sm4 = (({2'b00, bar4} << 2) - {2'b00, bar4} + {2'b00, g4} + 8'd2) >> 2;
    wire [7:0] sm5 = (({2'b00, bar5} << 2) - {2'b00, bar5} + {2'b00, g5} + 8'd2) >> 2;
    wire [7:0] sm6 = (({2'b00, bar6} << 2) - {2'b00, bar6} + {2'b00, g6} + 8'd2) >> 2;
    wire [7:0] sm7 = (({2'b00, bar7} << 2) - {2'b00, bar7} + {2'b00, g7} + 8'd2) >> 2;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            acc0 <= 24'd0; acc1 <= 24'd0; acc2 <= 24'd0; acc3 <= 24'd0;
            acc4 <= 24'd0; acc5 <= 24'd0; acc6 <= 24'd0; acc7 <= 24'd0;
            bar0 <= 6'd0;  bar1 <= 6'd0;  bar2 <= 6'd0;  bar3 <= 6'd0;
            bar4 <= 6'd0;  bar5 <= 6'd0;  bar6 <= 6'd0;  bar7 <= 6'd0;
            pk0  <= 6'd0;  pk1  <= 6'd0;  pk2  <= 6'd0;  pk3  <= 6'd0;
            pk4  <= 6'd0;  pk5  <= 6'd0;  pk6  <= 6'd0;  pk7  <= 6'd0;
            attn   <= 4'd6;
            pk_tog <= 1'b0;
        end
        else begin
            // ① 采样累加（帧边界处清零）
            if (I_samp_valid) begin
                acc0 <= acc0 + {10'd0, mag0};
                acc1 <= acc1 + {10'd0, mag1};
                acc2 <= acc2 + {10'd0, mag2};
                acc3 <= acc3 + {10'd0, mag3};
                acc4 <= acc4 + {10'd0, mag4};
                acc5 <= acc5 + {10'd0, mag5};
                acc6 <= acc6 + {10'd0, mag6};
                acc7 <= acc7 + {10'd0, mag7};
            end

            // ② 帧边界：清零累加器 + 更新柱高/峰值/自动增益
            if (I_vs_fall) begin
                acc0 <= 24'd0;
                acc1 <= 24'd0;
                acc2 <= 24'd0;
                acc3 <= 24'd0;
                acc4 <= 24'd0;
                acc5 <= 24'd0;
                acc6 <= 24'd0;
                acc7 <= 24'd0;

                pk_tog <= ~pk_tog;

                bar0 <= sm0[5:0];
                bar1 <= sm1[5:0];
                bar2 <= sm2[5:0];
                bar3 <= sm3[5:0];
                bar4 <= sm4[5:0];
                bar5 <= sm5[5:0];
                bar6 <= sm6[5:0];
                bar7 <= sm7[5:0];

                if (g0 >= pk0)                  pk0 <= g0;
                else if (pk_tog && pk0 != 6'd0) pk0 <= pk0 - 6'd1;
                if (g1 >= pk1)                  pk1 <= g1;
                else if (pk_tog && pk1 != 6'd0) pk1 <= pk1 - 6'd1;
                if (g2 >= pk2)                  pk2 <= g2;
                else if (pk_tog && pk2 != 6'd0) pk2 <= pk2 - 6'd1;
                if (g3 >= pk3)                  pk3 <= g3;
                else if (pk_tog && pk3 != 6'd0) pk3 <= pk3 - 6'd1;
                if (g4 >= pk4)                  pk4 <= g4;
                else if (pk_tog && pk4 != 6'd0) pk4 <= pk4 - 6'd1;
                if (g5 >= pk5)                  pk5 <= g5;
                else if (pk_tog && pk5 != 6'd0) pk5 <= pk5 - 6'd1;
                if (g6 >= pk6)                  pk6 <= g6;
                else if (pk_tog && pk6 != 6'd0) pk6 <= pk6 - 6'd1;
                if (g7 >= pk7)                  pk7 <= g7;
                else if (pk_tog && pk7 != 6'd0) pk7 <= pk7 - 6'd1;

                if (gmax < 6'd34 && attn != 4'd0)
                    attn <= attn - 4'd1;
                else if (gmax > 6'd44 && attn != 4'd15)
                    attn <= attn + 4'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 打包成 48bit 输出（段 0 在低位）
    //-------------------------------------------------------------------------
    assign O_bar  = {bar7, bar6, bar5, bar4, bar3, bar2, bar1, bar0};
    assign O_peak = {pk7,  pk6,  pk5,  pk4,  pk3,  pk2,  pk1,  pk0};

endmodule
