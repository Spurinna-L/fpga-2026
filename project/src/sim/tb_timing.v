`timescale 1ns / 1ps
// 640×480 时序快速验证：25MHz，测 3 个 VS 边沿之间的行数/像素数
module tb_timing;
    reg clk = 0;
    reg rst = 1;
    wire hs, vs, de;
    wire read_req;
    reg  read_req_ack = 0;

    video_timing_data u (
        .video_clk    (clk),
        .rst          (rst),
        .read_req     (read_req),
        .read_req_ack (read_req_ack),
        .hs           (hs),
        .vs           (vs),
        .de           (de)
    );

    always #20 clk = ~clk; // 25MHz

    integer hs_cnt = 0;
    integer de_cnt = 0;
    integer frames = 0;
    integer errors = 0;
    integer hs_prev = 0;
    integer de_prev = 0;
    reg hs_d = 0, vs_d = 0;

    always @(posedge clk) begin
        hs_d <= hs;
        vs_d <= vs;
        if (hs && !hs_d) hs_cnt <= hs_cnt + 1;
        if (de)          de_cnt <= de_cnt + 1;
        if (vs && !vs_d) begin
            if (frames > 0) begin
                $display("frame %0d: lines=%0d pixels=%0d", frames, hs_cnt - hs_prev, de_cnt - de_prev);
                if ((hs_cnt - hs_prev) != 525) begin
                    errors = errors + 1;
                    $display("FAIL: expect 525 lines/frame");
                end
                if ((de_cnt - de_prev) != 307200) begin
                    errors = errors + 1;
                    $display("FAIL: expect 307200 pixels/frame");
                end
            end
            hs_prev <= hs_cnt;
            de_prev <= de_cnt;
            frames  <= frames + 1;
        end
    end

    initial begin
        rst = 1;
        #200;
        rst = 0;
        #52_000_000; // > 3 frames
        $display("tb_timing: %0d frames, %0d errors", frames, errors);
        if (errors == 0) $display("tb_timing: PASS");
        else             $display("tb_timing: FAIL");
        $finish;
    end
endmodule
