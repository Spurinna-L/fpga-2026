//=============================================================================
// tb_bmp_scale.v — bmp_scale 自检
//-----------------------------------------------------------------------------
// 覆盖：
//   1) 640×480 逐像素旁路（模式与顺序）
//   2) 4:3 放大（320×240）
//   3) 16:9 上下黑边（160×90）
//   4) 竖图左右黑边（90×160）
//   5) 奇数宽度（641×481）行填充位不影响输出
//   6) 输出计数恰好 640×480
//=============================================================================
`timescale 1ns / 1ps

module tb_bmp_scale;

    localparam integer PIXELS = 640 * 480;

    reg         clk = 1'b0;
    reg         rst = 1'b1;

    reg         src_valid = 1'b0;
    reg  [23:0] src_data  = 24'd0;
    reg         src_config = 1'b0;
    reg  [15:0] src_width  = 16'd0;
    reg  [15:0] src_height = 16'd0;

    wire        out_valid;
    wire [23:0] out_data;
    wire        out_done;

    bmp_scale dut (
        .clk        (clk),
        .rst        (rst),
        .src_valid  (src_valid),
        .src_data   (src_data),
        .src_config (src_config),
        .src_width  (src_width),
        .src_height (src_height),
        .out_valid  (out_valid),
        .out_data   (out_data),
        .out_done   (out_done)
    );

    always #5 clk = ~clk;   // 100MHz

    integer errors    = 0;
    integer out_cnt   = 0;
    integer done_seen = 0;
    integer mode_test = 0;   // 0=solid, 1=bypass pattern, 2=2x2 双线性

    reg [15:0] exp_dw, exp_dh, exp_ox, exp_oy;
    reg [23:0] solid_color;

    // 计算保持比例后的内容矩形
    task set_geom;
        input integer w;
        input integer h;
        integer dw, dh;
        begin
            if ((w * 480) >= (h * 640)) begin
                dw = 640;
                dh = (h * 640) / w;
            end else begin
                dw = (w * 480) / h;
                dh = 480;
            end
            exp_dw = dw[15:0];
            exp_dh = dh[15:0];
            exp_ox = ((640 - dw) / 2);
            exp_oy = ((480 - dh) / 2);
        end
    endtask

    // 逐像素检查
    always @(posedge clk) begin
        if (out_valid) begin
            begin : check_pixel
                integer ox, oy;
                reg [23:0] exp;
                ox = out_cnt % 640;
                oy = out_cnt / 640;

                if (mode_test == 1) begin
                    exp = {ox[7:0], oy[7:0], 8'hA5};
                    if (out_data !== exp) begin
                        if (errors < 20)
                            $display("FAIL bypass idx=%0d got=%06h exp=%06h", out_cnt, out_data, exp);
                        errors = errors + 1;
                    end
                end else if (mode_test == 0) begin
                    if ((ox >= exp_ox) && (ox < (exp_ox + exp_dw)) &&
                        (oy >= exp_oy) && (oy < (exp_oy + exp_dh)))
                        exp = solid_color;
                    else
                        exp = 24'h000000;
                    if (out_data !== exp) begin
                        if (errors < 20)
                            $display("FAIL solid idx=%0d x=%0d y=%0d got=%06h exp=%06h",
                                     out_cnt, ox, oy, out_data, exp);
                        errors = errors + 1;
                    end
                end else if (mode_test == 2) begin
                    // 2×2 源图：row0 = 黑/白，row1 = 白/黑，内容区 480×480 @ x=80
                    if ((out_cnt == 80) || (out_cnt == 307119)) begin
                        if (out_data !== 24'h000000) begin
                            $display("FAIL 2x2 corner idx=%0d got=%06h exp=000000", out_cnt, out_data);
                            errors = errors + 1;
                        end
                    end else if ((out_cnt == 559) || (out_cnt == 306640)) begin
                        if (out_data !== 24'hFFFFFF) begin
                            $display("FAIL 2x2 corner idx=%0d got=%06h exp=FFFFFF", out_cnt, out_data);
                            errors = errors + 1;
                        end
                    end else if (out_cnt == 153279) begin
                        if ((out_data[23:16] < 124) || (out_data[23:16] > 132) ||
                            (out_data[15:8]  < 124) || (out_data[15:8]  > 132) ||
                            (out_data[7:0]   < 124) || (out_data[7:0]   > 132)) begin
                            $display("FAIL 2x2 center got=%06h (expect ~808080)", out_data);
                            errors = errors + 1;
                        end
                    end
                end

                if (out_cnt == PIXELS - 1)
                    done_seen = 1;
                out_cnt = out_cnt + 1;
            end
        end
    end

    task send_image;
        input integer w;
        input integer h;
        input [23:0] color;
        input integer pattern_mode;   // 0=solid, 1=bypass pattern, 2=2x2
        integer x, y;
        begin
            out_cnt    = 0;
            done_seen  = 0;
            mode_test  = pattern_mode;
            solid_color = color;
            set_geom(w, h);

            @(posedge clk);
            src_width  <= w[15:0];
            src_height <= h[15:0];
            @(posedge clk);
            src_config <= 1'b1;
            @(posedge clk);
            src_config <= 1'b0;

            for (y = 0; y < h; y = y + 1) begin
                for (x = 0; x < w; x = x + 1) begin
                    while (!dut.src_ready) @(posedge clk);
                    @(posedge clk);
                    src_valid <= 1'b1;
                    if (pattern_mode == 1)
                        src_data <= {x[7:0], y[7:0], 8'hA5};
                    else if (pattern_mode == 2)
                        src_data <= (((x == 0) && (y == 0)) || ((x == 1) && (y == 1)))
                                    ? 24'h000000 : 24'hFFFFFF;
                    else
                        src_data <= color;
                    @(posedge clk);
                    src_valid <= 1'b0;
                    repeat (14) @(posedge clk);  // 16 clocks/pixel，模拟慢速 SD，避免 FIFO 溢出
                end
            end

            // 等输出完成（最多 3M 拍）
            begin : wait_done
                integer t;
                t = 0;
                while (!done_seen && (t < 8000000)) begin
                    @(posedge clk);
                    t = t + 1;
                end
                if (!done_seen) begin
                    $display("TIMEOUT: %0dx%0d out_cnt=%0d out_y=%0d out_x=%0d",
                             w, h, out_cnt, dut.out_y, dut.out_x);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        send_image(640, 480, 24'h000000, 1);
        if (out_cnt == PIXELS)
            $display("PASS bypass 640x480: %0d pixels", out_cnt);
        else
            $display("FAIL bypass count=%0d", out_cnt);

        send_image(2, 2, 24'h000000, 2);
        if (out_cnt == PIXELS)
            $display("PASS 2x2 -> 480x480 + side bars");
        else
            $display("FAIL 2x2 count=%0d", out_cnt);

        send_image(320, 240, 24'h336699, 0);
        if (out_cnt == PIXELS)
            $display("PASS 320x240 -> 640x480");
        else
            $display("FAIL 320x240 count=%0d", out_cnt);

        send_image(160, 90, 24'hAA5500, 0);
        if (out_cnt == PIXELS)
            $display("PASS 160x90 -> 640x360 + bars");
        else
            $display("FAIL 160x90 count=%0d", out_cnt);

        send_image(90, 160, 24'h00AA88, 0);
        if (out_cnt == PIXELS)
            $display("PASS 90x160 -> 270x480 + bars");
        else
            $display("FAIL 90x160 count=%0d", out_cnt);

        send_image(641, 481, 24'h123456, 0);
        if (out_cnt == PIXELS)
            $display("PASS 641x481 -> 639x480 + 1px bar");
        else
            $display("FAIL 641x481 count=%0d", out_cnt);

        $display("--------------------------------------------------");
        if (errors == 0)
            $display("tb_bmp_scale: PASS");
        else
            $display("tb_bmp_scale: %0d errors", errors);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
