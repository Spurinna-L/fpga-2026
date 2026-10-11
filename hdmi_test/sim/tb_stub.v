//=============================================================================
// tb_stub.v  —  stub_source 自测：把它产生的像素流直接 dump 成 BMP
//-----------------------------------------------------------------------------
// 目的：先单独确认"假数据源自己的图"是对的，再拿它去测帧缓冲。
//=============================================================================
`timescale 1ns / 1ps

module tb_stub;

    localparam W = 1280;
    localparam H = 720;

    reg clk = 0;
    always #10 clk = ~clk;      // 50 MHz

    reg rst_n = 0;

    wire        px_we;
    wire [10:0] px_x, px_y;
    wire [15:0] px_pix;
    wire        frame_done;

    stub_source #(.W(W), .H(H)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .stall     (1'b0),
        .frame_id  (8'd0),
        .px_we     (px_we),
        .px_x      (px_x),
        .px_y      (px_y),
        .px_pix    (px_pix),
        .frame_done(frame_done)
    );

    // RGB565 -> RGB888
    wire [7:0] r8 = {px_pix[15:11], px_pix[15:13]};
    wire [7:0] g8 = {px_pix[10:5],  px_pix[10:9]};
    wire [7:0] b8 = {px_pix[4:0],   px_pix[4:2]};

    integer fd;
    integer cnt  = 0;
    reg     done = 1'b0;

    task bmp_u16; input [15:0] v;
        begin
            $fwrite(fd, "%c", v[7:0]);
            $fwrite(fd, "%c", v[15:8]);
        end
    endtask

    task bmp_u32; input [31:0] v;
        begin
            $fwrite(fd, "%c", v[7:0]);
            $fwrite(fd, "%c", v[15:8]);
            $fwrite(fd, "%c", v[23:16]);
            $fwrite(fd, "%c", v[31:24]);
        end
    endtask

    initial begin
        fd = $fopen("stub_frame.bmp", "wb");
        if (fd == 0) begin $display("[tb] ERROR: 无法创建 stub_frame.bmp"); $finish; end

        bmp_u16(16'h4D42);
        bmp_u32(W*3*H + 54);
        bmp_u32(0);
        bmp_u32(54);
        bmp_u32(40);
        bmp_u32(W);
        bmp_u32(-H);
        bmp_u16(1);
        bmp_u16(24);
        bmp_u32(0);
        bmp_u32(W*3*H);
        bmp_u32(2835);
        bmp_u32(2835);
        bmp_u32(0);
        bmp_u32(0);

        $display("[tb] stub_source 出图开始 ...");
        #100 rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && !done && px_we) begin
            $fwrite(fd, "%c%c%c", b8, g8, r8);   // BMP = BGR
            cnt <= cnt + 1;
            if (cnt == W*H - 1) begin
                done <= 1'b1;
                $fclose(fd);
                $display("[tb] stub_source 出图完成：%0dx%0d -> stub_frame.bmp", W, H);
                $finish;
            end
        end
    end

    initial begin
        #40_000_000;
        $display("[tb] TIMEOUT");
        $fclose(fd);
        $finish;
    end

endmodule
