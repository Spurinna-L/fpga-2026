//=============================================================================
// lane_lvds_10_1.v — 单 lane TMDS 10:1 串行化
//-----------------------------------------------------------------------------
// 功能：
//   像素域产生 odd/even 半拍标志；串行域用 2FF 同步后检测跳变得到 load_en，
//   每次装载 10bit，之后每拍左移 2bit，取高 2bit 送 ODDR 以 DDR 方式输出，
//   从而把 10bit@25MHz 变成 1bit@125MHz DDR（等效 250Mbps/lane）。
//
// 时钟：I_pixel_clk = 25MHz；I_serial_clk = 125MHz。
// 复位：I_rst 高有效。
//
// 接口：
//   in  I_data_in[9:0]   并行 TMDS 字符
//   out O_serial_out     串行单端输出（接 ODDR → 差分）
//
// 参数：
//   DEVICE = "EG"    generate 选择 EG/EF2/EF3/EF4/SF1/PH1A/PH1P/DR1 的 ODDR
//
// 内部例化：
//   EG_LOGIC_ODDR（当前 DEVICE="EG" 分支）
//
// 备注：
//   odd/even 跨时钟用 2FF，load 脉冲再打两拍对齐，属于“慢变标志 + 边沿检测”
//   的跨域方式，不是数据总线跨域。
//=============================================================================
module lane_lvds_10_1 #(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_rst,

    input wire[9:0] I_data_in,

    output wire     O_serial_out
);

    reg      S_odd_even;     
    reg      S_odd_even_1d;  
    reg      S_odd_even_2d;  
    reg      S_load_en;      
    reg      S_load_en_1d;   
    reg      S_load_en_2d;   
    reg[9:0] S_shift_data;   
    reg[1:0] S_oddr_data;    


    always @(posedge I_pixel_clk or posedge I_rst) begin
        if(I_rst)
            S_odd_even <= 1'b0;
        else
            S_odd_even <= ~S_odd_even;
    end

    always @(posedge I_serial_clk) begin
        S_odd_even_1d <= S_odd_even;
        S_odd_even_2d <= S_odd_even_1d;
    end

    always @(posedge I_serial_clk) begin
        S_load_en    <= S_odd_even_1d ^ S_odd_even_2d;
        S_load_en_1d <= S_load_en;
        S_load_en_2d <= S_load_en_1d;
    end

    always @(posedge I_serial_clk or posedge I_rst) begin
        if(I_rst)
            S_shift_data <= 'd0;
        else
            if(S_load_en_2d)
                S_shift_data <= I_data_in;
            else 
                S_shift_data <= S_shift_data << 2;
    end

    always @(posedge I_serial_clk) begin
        S_oddr_data <= S_shift_data[9:8];
    end

    generate
        if(DEVICE == "EF2")
            begin
                EF2_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF3")
            begin
                EF3_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EF4")
            begin
                EF4_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "SF1")
            begin
                SF1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "EG")
            begin
                EG_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1A")
            begin
                PH1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "PH1P")
            begin
                PH1P_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
        else if(DEVICE == "DR1")
            begin
                DR1_LOGIC_ODDR U_EG4_ODDR(
                    .clk   ( I_serial_clk   ),
                    .rst   ( I_rst          ),

                    .d1    ( S_oddr_data[0] ),
                    .d0    ( S_oddr_data[1] ),

                    .q     ( O_serial_out   )
                );
            end
    endgenerate
    
endmodule
