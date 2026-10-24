//=============================================================================
// tb_video.v  —  720p 视频链仿真台（里程碑 M1 的"软件版"）
//-----------------------------------------------------------------------------
// 目的：不上板，用 iverilog 把 video_timing_720p + test_pattern 跑起来，产出两样东西：
//   1) frame.bmp   —— 真的把"一帧画面"算出来存成图片（可直接打开看）
//   2) wave.vcd    —— 波形，用 GTKWave 看 hs/vs/de/x/y 的扫描节奏
//
// 用法：见同目录 run.ps1 / README.md
//
// 关键认知：所谓"图像"不是魔法——就是 de=1 的每一拍，(x,y) 处算出一个 RGB 值。
//           本仿真台把这些像素按扫描顺序写进 BMP，于是你就"看见"了这段逻辑。
//=============================================================================
`timescale 1ns / 1ps

module tb_video;

    // 目标画面尺寸（与 video_timing_720p 一致）
    localparam integer W = 1280;
    localparam integer H = 720;

    //-------------------------------------------------------------------
    // 像素时钟：75MHz（周期 13.334ns）
    //-------------------------------------------------------------------
    reg clk_pix = 1'b0;
    always #6.667 clk_pix = ~clk_pix;

    reg rst_n = 1'b0;

    //-------------------------------------------------------------------
    // DUT 连线
    //-------------------------------------------------------------------
    wire        hs, vs, de;
    wire [10:0] x, y;
    wire        frame_start, line_start;
    wire [15:0] rgb;

    video_timing_720p u_timing (
        .clk_pix    (clk_pix),
        .rst_n      (rst_n),
        .hs         (hs),
        .vs         (vs),
        .de         (de),
        .x          (x),
        .y          (y),
        .frame_start(frame_start),
        .line_start (line_start)
    );

    test_pattern u_pattern (
        .clk_pix (clk_pix),
        .rst_n   (rst_n),
        .de      (de),
        .x       (x),
        .y       (y),
        .rgb     (rgb)
    );

    //-------------------------------------------------------------------
    // RGB565 -> RGB888（BMP 用 24bit）
    //-------------------------------------------------------------------
    wire [7:0] r8 = {rgb[15:11], rgb[15:13]};
    wire [7:0] g8 = {rgb[10:5],  rgb[10:9]};
    wire [7:0] b8 = {rgb[4:0],   rgb[4:2]};

    //-------------------------------------------------------------------
    // BMP 输出
    //-------------------------------------------------------------------
    integer fd;
    integer px_cnt = 0;
    integer cyc    = 0;
    reg     done   = 1'b0;
    reg     frame_mode = 1'b0;

    // 监视器：只把"慢速"控制信号暴露给整帧波形，避免 VCD 体积爆炸
    frame_mon u_mon (
        .hs         (hs),
        .vs         (vs),
        .de         (de),
        .y          (y),
        .frame_start(frame_start),
        .line_start (line_start)
    );

    // 小端写入
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
        // ---- 波形模式：默认出"细节窗口"；带 +FRAME 参数则出"整帧结构" ----
        if ($test$plusargs("FRAME")) begin
            frame_mode = 1'b1;
            $dumpfile("wave_frame.vcd");
            $dumpvars(0, u_mon);              // 只 dump 慢速控制信号 → 体积小
        end else begin
            frame_mode = 1'b0;
            $dumpfile("wave_detail.vcd");
            $dumpvars(0, tb_video);           // 全部信号 → 看像素级细节
        end

        fd = $fopen("frame.bmp", "wb");
        if (fd == 0) begin
            $display("[tb] ERROR: 无法创建 frame.bmp");
            $finish;
        end

        // ---- 54 字节 BMP 头（24bit，负高度=自顶向下，行宽 1280*3=3840 已 4 对齐）----
        bmp_u16(16'h4D42);            // 'BM'
        bmp_u32(W*3*H + 54);          // 文件大小
        bmp_u32(0);                   // 保留
        bmp_u32(54);                  // 像素数据偏移
        bmp_u32(40);                  // 信息头大小
        bmp_u32(W);                   // 宽
        bmp_u32(-H);                  // 高（负 = 自顶向下）
        bmp_u16(1);                   // 颜色平面
        bmp_u16(24);                  // 位深
        bmp_u32(0);                   // 压缩方式（0=不压缩）
        bmp_u32(W*3*H);               // 像素数据大小
        bmp_u32(2835);                // 水平分辨率
        bmp_u32(2835);                // 垂直分辨率
        bmp_u32(0);                   // 调色板颜色数
        bmp_u32(0);                   // 重要颜色数

        $display("[tb] BMP 头已写入，等待复位释放...");
        #200 rst_n = 1'b1;
    end

    // 逐像素抓取：de=1 时按扫描顺序写 BMP（BMP 为 BGR 顺序）
    always @(posedge clk_pix) begin
        if (rst_n && !done && de) begin
            $fwrite(fd, "%c%c%c", b8, g8, r8);
            px_cnt <= px_cnt + 1;
            if (px_cnt == W*H - 1) begin
                done <= 1'b1;
                $fclose(fd);
                $display("[tb] 抓取完成：%0d 像素（%0dx%0d），frame.bmp 已生成", W*H, W, H);
                $display("[tb] 仿真结束。用 GTKWave 打开 wave.vcd。");
                $finish;
            end
        end
    end

    // 细节窗口：只 dump 前 60000 个周期（约 36 行），控制 VCD 体积
    always @(posedge clk_pix) begin
        cyc <= cyc + 1;
        if (!frame_mode && cyc == 60000) begin
            $dumpoff;
            $display("[tb] 细节波形窗口结束（60000 周期）");
        end
    end

    // 超时保护：40ms 仿真时间（约 2.4 帧）还没抓完就报错退出
    initial begin
        #40_000_000;
        $display("[tb] TIMEOUT：未在预期时间抓完一帧");
        $fclose(fd);
        $finish;
    end

endmodule


//-----------------------------------------------------------------------------
// 波形监视器：仅有端口、无逻辑，用于把慢速控制信号"打包"进小体积 VCD
//-----------------------------------------------------------------------------
module frame_mon (
    input wire        hs,
    input wire        vs,
    input wire        de,
    input wire [10:0] y,
    input wire        frame_start,
    input wire        line_start
);
endmodule
