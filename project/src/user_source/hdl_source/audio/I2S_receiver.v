//=============================================================================
// I2S_receiver.v — I2S 从机解串（过采样，跨时钟安全）
//-----------------------------------------------------------------------------
// 功能：
//   用 I_clk 对 BCLK/LRCK/DOUT 各做 3 级同步，检测 BCLK 上升沿后移位；
//   依据 LRCK 电平区分左右声道，在 LRCK 跳变沿锁存 24bit 样本，
//   在右声道结束时输出一拍 O_audio_valid 并同时给出左右样本。
//
// 时钟/复位：I_clk = video_clk 25MHz（远高于 BCLK 6.144MHz，满足过采样）。
//
// 接口：
//   in  I_i2s_BCLK / I_i2s_LRCK / I_i2s_DOUT
//   out O_audio_valid        左右样本有效（单拍）
//   out O_audio_left_data[23:0] / O_audio_right_data[23:0]
//
// 参数：无
//
// 内部例化：无
//
// 备注：
//   I_rst 端口保留但内部各 always 块未使用（无复位逻辑），
//   上电后移位寄存器自然收敛；新增逻辑时请显式使用 I_rst。
//=============================================================================
module I2S_receiver (
    input wire       I_clk,
    input wire       I_rst,
  
    input wire       I_i2s_BCLK,
    input wire       I_i2s_LRCK,
    input wire       I_i2s_DOUT,

    output reg       O_audio_valid,
    output reg[23:0] O_audio_left_data,
    output reg[23:0] O_audio_right_data
);


    reg       S_i2s_bclk_1d;
    reg       S_i2s_bclk_2d;
    reg       S_i2s_bclk_3d;
  
    wire      S_i2s_bclk_p_edge;  
  
    reg       S_i2s_lrck_1d;
    reg       S_i2s_lrck_2d;
    reg       S_i2s_lrck_3d;
    reg       S_i2s_lrck_sync;
    wire      S_i2s_lrck_p_edge;
    wire      S_i2s_lrck_n_edge;
  
    reg       S_i2s_dout_1d;
    reg       S_i2s_dout_2d;
    reg       S_i2s_dout_3d;

    reg[63:0] S_left_shift_data;
    reg[63:0] S_right_shift_data;

    reg       S_left_data_valid;
    reg       S_right_data_valid;

    reg[63:0] S_left_data_lock;

    always @(posedge I_clk) begin
        S_i2s_bclk_1d <= I_i2s_BCLK;
        S_i2s_bclk_2d <= S_i2s_bclk_1d;
        S_i2s_bclk_3d <= S_i2s_bclk_2d;

        S_i2s_lrck_1d <= I_i2s_LRCK;
        S_i2s_lrck_2d <= S_i2s_lrck_1d;
        S_i2s_lrck_3d <= S_i2s_lrck_2d;

        S_i2s_dout_1d <= I_i2s_DOUT;
        S_i2s_dout_2d <= S_i2s_dout_1d;
        S_i2s_dout_3d <= S_i2s_dout_2d;
    end

    assign S_i2s_bclk_p_edge = ~S_i2s_bclk_3d & S_i2s_bclk_2d;


    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge)
            S_i2s_lrck_sync <= S_i2s_lrck_3d;
        else
            S_i2s_lrck_sync <= S_i2s_lrck_sync;
    end

    assign S_i2s_lrck_p_edge = ~S_i2s_lrck_sync & S_i2s_lrck_3d;

    assign S_i2s_lrck_n_edge = ~S_i2s_lrck_3d & S_i2s_lrck_sync;

    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge)
            if(S_i2s_lrck_sync)
                begin
                    S_right_shift_data <= {S_right_shift_data[62:0],S_i2s_dout_3d};
                    S_left_shift_data  <= 'd0;
                end
            else
                begin
                    S_right_shift_data <= 'd0;
                    S_left_shift_data  <= {S_left_shift_data[62:0],S_i2s_dout_3d};
                end
        else
            begin
                S_right_shift_data <= S_right_shift_data;
                S_left_shift_data  <= S_left_shift_data;
            end
    end


    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge && S_i2s_lrck_p_edge)
            S_left_data_valid <= 1'b1;
        else
            S_left_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if(S_i2s_bclk_p_edge && S_i2s_lrck_n_edge)
            S_right_data_valid <= 1'b1;
        else
            S_right_data_valid <= 1'b0;
    end

    always @(posedge I_clk) begin
        if(S_left_data_valid)
            S_left_data_lock <= S_left_shift_data;
        else
            S_left_data_lock <= S_left_data_lock;
    end

    always @(posedge I_clk) begin
        if(S_right_data_valid)
            begin
                O_audio_valid      <= 1'b1;
                O_audio_left_data  <= S_left_data_lock[63:40];
                O_audio_right_data <= S_right_shift_data[63:40];
            end
        else
            begin
                O_audio_valid      <= 1'b0;
                O_audio_left_data  <= 'd0;
                O_audio_right_data <= 'd0;
            end
    end

    // always @(posedge I_clk) begin
    //     if(S_i2s_bclk_p_edge)
    //         begin
    //             if(S_i2s_lrck_3d)
    //                 begin
    //                     S_right_channel_cnt <= S_right_channel_cnt + 1'b1;
    //                     S_left_channel_cnt  <= 'd0;
    //                 end
    //             else    
    //                 begin
    //                     S_right_channel_cnt <= 'd0;
    //                     S_left_channel_cnt  <= S_left_channel_cnt + 1'b1;
    //                 end
    //         end
    //     else
    //         begin
    //             S_right_channel_cnt <= S_right_channel_cnt;
    //             S_left_channel_cnt  <= S_left_channel_cnt;
    //         end
    // end


    

endmodule
