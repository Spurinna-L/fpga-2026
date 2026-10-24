//=============================================================================
// audio_arc_calculate.v — HDMI 音频时钟再生（ACR）参数生成
//-----------------------------------------------------------------------------
// 功能：
//   对 48kHz 音频有效脉冲计数，每 AUDIO_DIV 个样本产生一次 acr_valid
//   （AUDIO_DIV = ACR_N>>7 = 48，即 1ms 一次）；两次 acr_valid 之间统计
//   I_clk 周期数作为 CTS 输出，N 固定为 ACR_N。HDMI 核用 (CTS,N) 在接收端
//   恢复音频采样时钟。
//
// 时钟/复位：I_clk = video_clk 25MHz；I_rst 高有效。
//
// 接口：
//   in  I_audio_valid       音频样本有效（来自 I2S_receiver）
//   out O_acr_valid         ACR 更新脉冲
//   out O_acr_cts[19:0]     两次更新之间的像素时钟数
//   out O_acr_n[19:0]       ACR_N
//
// 参数：
//   ACR_N = 6144   → AUDIO_DIV = 48
//
// 内部例化：无
//=============================================================================
module audio_arc_calculate #(
    parameter ACR_N = 6144
    )(
    input wire       I_clk,
    input wire       I_rst,

    input wire       I_audio_valid,

    output reg       O_acr_valid,
    output reg[19:0] O_acr_cts,
    output reg[19:0] O_acr_n
);


    localparam AUDIO_DIV = ACR_N >> 7;

    reg[7:0]  S_audio_div_cnt;
    wire      S_audio_valid_div;
    reg[19:0] S_acr_cts_cnt;


    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_audio_div_cnt <= 'd0;
        else
            if(I_audio_valid)
                begin
                    if(S_audio_div_cnt >= AUDIO_DIV-1)
                        S_audio_div_cnt <= 'd0;
                    else
                        S_audio_div_cnt <= S_audio_div_cnt + 'd1;
                end
            else
                S_audio_div_cnt <= S_audio_div_cnt;
    end


    assign S_audio_valid_div = I_audio_valid && (S_audio_div_cnt == AUDIO_DIV-1) ? 1'b1 : 1'b0;

    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)
            S_acr_cts_cnt <= 'd0;
        else
            if(S_audio_valid_div)
                S_acr_cts_cnt <= 'd0;
            else
                S_acr_cts_cnt <= S_acr_cts_cnt + 'd1;
    end


    always @(posedge I_clk) begin
        if(S_audio_valid_div)
            begin
                O_acr_valid <= 1'b1;
                O_acr_cts   <= S_acr_cts_cnt + 'd1;
                O_acr_n     <= ACR_N;
            end
        else    
            begin
                O_acr_valid <= 1'b0;
                O_acr_cts   <= 'd0;
                O_acr_n     <= 'd0;
            end
    end

    
endmodule
