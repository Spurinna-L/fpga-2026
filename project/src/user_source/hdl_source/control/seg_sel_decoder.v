//=============================================================================
// seg_sel_decoder.v — 2bit 位索引 → 4 位数码管位选
//-----------------------------------------------------------------------------
// 功能：
//   bit_disp=0/1/2/3 时分别输出 1110/1101/1011/0111（低有效 one-hot）。
//
// 接口：
//   in  bit_disp[1:0]  当前扫描位
//   out seg_sel[3:0]   位选输出
//
// 内部例化：无
//=============================================================================
module seg_sel_decoder(bit_disp,seg_sel);
    input [1:0] bit_disp;
    output reg [3:0] seg_sel;
    always@(bit_disp)
        case(bit_disp)
            2'b00 : seg_sel = 4'b1110;
            2'b01 : seg_sel = 4'b1101;            
            2'b10 : seg_sel = 4'b1011;
            2'b11 : seg_sel = 4'b0111;
            default : seg_sel = 4'b1111;
        endcase
endmodule
