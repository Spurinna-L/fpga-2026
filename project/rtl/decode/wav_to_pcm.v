//=============================================================================
// wav_to_pcm.v  —  把 WAV 文件字节流解析成 16bit PCM，并写进 BRAM
//-----------------------------------------------------------------------------
// 【它在整条链里的位置】
//
//   SD 卡 ──SPI──▶ sd_ctrl ──▶ fat32_reader ──字节流──▶ ┌───────────────┐
//                                                       │  wav_to_pcm   │(本文件)
//                                                       └───────┬───────┘
//                                 16bit PCM + 写地址/写使能    │
//                                                               ▼
//                                                        ┌────────────┐
//                                                        │ audio_bram │
//                                                        └─────┬──────┘
//                                                          读出采样
//                                                               ▼
//                                            r2r_dac_player ──▶ R-2R DAC ──▶ 喇叭
//
// ============================================================================
// 一、先搞懂「WAV 文件到底是什么」
// ============================================================================
//  .wav 文件不是神秘东西，它就是「一串字节」，按固定格式排好队而已。
//  打开看是这样(全部小端序 little-endian)：
//
//    偏移   长度   内容            说明
//    --------------------------------------------------------------
//    0      4      "RIFF"          魔数，固定这 4 个字母
//    4      4      文件长度         整个文件字节数 - 8（本模块不关心）
//    8      4      "WAVE"          固定 4 个字母，表示这是 WAVE 格式
//    12     4      块ID            通常是 "fmt "
//    16     4      块大小           这个块后面跟多少字节
//    20     N      块内容
//    ...            （后面还可以有若干个块，每个都是
//                    [4字节ID][4字节大小][内容] 这样一段）
//
//  我们只关心两种"块(chunk)"：
//    * "fmt " 块：里面写着 声道数、采样率、位宽 等参数；
//    * "data" 块：里面就是 一个个真正的音频采样（我们要的数据）。
//    其它块（LIST、fact…）一律跳过。
//
//  "fmt " 块内容（前 16 字节，全部小端）：
//    偏移(块内) 长度  字段            含义
//    --------------------------------------------------------------
//    0..1       2     audioFormat     1 = PCM(未压缩)，我们就认 1
//    2..3       2     numChannels     1=单声道  2=立体声
//    4..7       4     sampleRate      采样率 44100/48000…
//    8..11      4     byteRate        每秒字节数（用不到）
//    12..13     2     blockAlign      每个"采样帧"多少字节 = 声道数 × 位宽/8
//    14..15     2     bitsPerSample   位宽 8 或 16
//
//  "data" 块内容：按 blockAlign 一组一组排：
//    * 16bit 单声道：每 2 字节 = 1 个采样（小端：低字节在前）
//    * 16bit 立体声：每 4 字节 = 左(2字节) + 右(2字节)
//    * 8bit  是"无符号"，要减 128 变成有符号后再对齐到 16bit；
//      16bit 本身就是"有符号补码"，直接用。
//
// ============================================================================
// 二、本模块怎么工作（状态机顺着字节流往前走）
// ============================================================================
//   字节到来(valid)且我们准备好(ready) ⇒ 消费 1 个字节，状态机前进一步：
//
//     S_RIFF → S_RSIZE → S_WAVE
//         → 循环 { S_CID → S_CSIZE → (S_FMT | S_SKIP | S_DATA) }
//         → S_DONE
//
//   走到 S_DATA 后：每凑满一个"帧"(blockAlign 字节)就把 左右声道合成
//   1 个 16bit 单声道采样，写进 BRAM（写地址自动 +1，写满回卷）。
//   立体声下混公式： pcm = (左 + 右) >>> 1   （右移1位=除以2，且保持符号）
//
//   为什么要"下混成单声道"？
//     本项目的 R-2R DAC 只有一路输出，播放立体声也只能听到一路；
//     下混成单声道信息更全，也省一半 BRAM 空间。
//
// ============================================================================
// 三、握手接口怎么接？（valid / ready）
// ============================================================================
//   传输规则：当 s_valid=1 且 s_ready=1 的同一个时钟沿，"消费"掉 s_data 这个字节。
//
//   【流式播放·重要】本模块是"边收边写"的，不等待整个文件：
//     * 每凑满一帧(p_now)就立刻写入 BRAM，写指针 wr_ptr 自动回卷；
//     * 上层用 bp_pause 做背压——环形缓冲快满时拉高，本模块随即把 s_ready 拉低，
//       上游(FAT/SD)应暂停送字节，直到缓冲被播放器读走一部分再恢复。
//   * 如果上游是 show-ahead FIFO（数据现成摆在总线上）：
//       把 FIFO 的 rd_data 接 s_data、FIFO 的 !empty 接 s_valid、
//       用 s_ready 当作 FIFO 的 rd_req（取出并前进）。
//   * 本模块在 S_DONE 之后 s_ready=0，自然就不再要数据了。
//=============================================================================
`timescale 1ns / 1ps

module wav_to_pcm #(
    // BRAM 地址位宽：AW=15 → 深度 32768 个 16bit 采样（≈0.68 秒 @48kHz）
    parameter integer AW    = 15,
    parameter integer DEPTH = (1 << AW)
)(
    input  wire          clk,             // 工作时钟（本工程接 50MHz）
    input  wire          rst_n,           // 低有效复位

    // ---------- 输入：来自 FAT/SD 的 WAV 文件字节流 ----------
    input  wire          s_valid,         // 本拍 s_data 有效
    input  wire [7:0]    s_data,          // 1 个字节
    output wire          s_ready,         // 本模块能接收（valid&ready 同拍 = 消费）
    input  wire          bp_pause,        // 背压：=1 时暂停接收（环形缓冲快满，见顶层）

    // ---------- 输出：写 BRAM（由 audio_bram 的写口接收）----------
    output reg           bram_we,         // 写使能（1 拍脉冲）
    output reg  [AW-1:0] bram_addr,       // 写地址（自动 +1，写满回卷）
    output reg  [15:0]   bram_data,       // 要写的 16bit PCM（有符号）

    // ---------- 输出：状态 / 文件信息（供上层显示和播放器使用）----------
    output reg  [31:0]   sample_count,    // 已经写进 BRAM 的采样个数
    output reg  [31:0]   sample_rate,     // 采样率（解析自 fmt 块）
    output reg  [15:0]   channels,        // 声道数
    output reg  [15:0]   bits,            // 位宽
    output reg           header_ok,       // 头部解析成功（拿到 fmt 参数）
    output reg           load_done,       // data 块读完（整段音频已进 BRAM）
    output reg           load_active      // 正在写入 data（=1 表示正在灌数据）
);

    //-------------------------------------------------------------------------
    // 0) 状态编码 & 魔数常量
    //-------------------------------------------------------------------------
    localparam [3:0] S_RIFF   = 4'd0;   // 收 "RIFF"
    localparam [3:0] S_RSIZE  = 4'd1;   // 跳过 4 字节文件长度
    localparam [3:0] S_WAVE   = 4'd2;   // 收 "WAVE"
    localparam [3:0] S_CID    = 4'd3;   // 收 4 字节块 ID
    localparam [3:0] S_CSIZE  = 4'd4;   // 收 4 字节块大小
    localparam [3:0] S_FMT    = 4'd5;   // 读 "fmt " 块内容
    localparam [3:0] S_SKIP   = 4'd6;   // 跳过不关心的块
    localparam [3:0] S_DATA   = 4'd7;   // 抓取 PCM 采样写 BRAM
    localparam [3:0] S_PAD    = 4'd8;   // 跳过块尾的 1 字节对齐填充
    localparam [3:0] S_DONE   = 4'd9;   // 全部读完

    // 魔数：按"字节到达顺序"拼成，最高字节 = 第一个到达的字符
    localparam [31:0] M_RIFF = 32'h52494646;  // 'R''I''F''F'
    localparam [31:0] M_WAVE = 32'h57415645;  // 'W''A''V''E'
    localparam [31:0] M_FMT  = 32'h666D7420;  // 'f''m''t'' '
    localparam [31:0] M_DATA = 32'h64617461;  // 'd''a''t''a'

    //-------------------------------------------------------------------------
    // 1) 寄存器声明
    //-------------------------------------------------------------------------
    reg [3:0]  st;            // 主状态
    reg [2:0]  bcnt;          // 一个 4 字节字段里的字节序号 0..3
    reg [31:0] idbuf;         // 暂存 4 字节"块 ID"（先到的放高位）
    reg [31:0] sz_be;         // 暂存 4 字节"块大小"（大端暂存，方便翻转）
    reg [31:0] chunk_size;    // 当前块大小（已翻转成正确的 LE 值）
    reg [31:0] chunk_left;    // 跳过块时，还剩多少字节没跳
    reg [31:0] fread;         // "fmt " 块里已读字节数（0..）
    reg [31:0] data_left;     // "data" 块还剩多少字节没读

    // "fmt " 各字段
    reg [15:0] f_audiofmt;    // 音频格式（1=PCM）
    reg [31:0] f_byterate;    // 每秒字节数（读进来但用不到）
    reg [15:0] f_blockalign;  // 每个采样帧字节数（读进来但用不到，我们用声道×位宽算）

    // "data" 抓采样用：按字节缓存一个采样帧（最多 4 字节）
    reg [7:0]  fb0, fb1, fb2, fb3;   // 帧内第 0/1/2/3 个字节
    reg [3:0]  dcnt;          // 帧内已收字节数
    reg [7:0]  bpf;           // bytes-per-frame = 声道数 × (位宽/8)

    // BRAM 写指针：真正“下一个该写哪个地址”由它记。
    // 【关键】bram_addr/bram_data/bram_we 是“同拍更新”的一组寄存器，
    // 而 BRAM 是在下一拍才采样这组寄存器。所以写地址必须取“当前指针值”，
    // 指针再下一拍才 +1，否则整段数据会整体错位一格（写到了 A+1）。
    reg [AW-1:0] wr_ptr;

    //-------------------------------------------------------------------------
    // 2) 握手信号
    //    s_ready = ① 文件还没读完  且  ② 上层没在要求暂停（环形缓冲未满）
    //    两者任一为假都拉低 s_ready，上游就暂停送字节（流式回压）。
    //-------------------------------------------------------------------------
    assign s_ready  = (st != S_DONE) & ~bp_pause;
    wire  byte_take = s_valid & s_ready;

    // 本拍是不是"一个采样帧的最后一个字节"
    wire is_last = ((dcnt + 4'd1) == bpf[3:0]);

    //-------------------------------------------------------------------------
    // 3) 采样合成（把一帧的 1~4 个字节变成 1 个 16bit 有符号采样）
    //    小端序：先到的字节是「低字节」，所以 16bit 采样 = {后字节, 前字节}。
    //    这里用 nbX 表示「把本拍字节算进去之后」帧内第 X 个字节的值。
    //    * 16bit：L = {nb1,nb0}，R = {nb3,nb2}
    //    * 8bit ：无符号，减 128 后有符号，左移 8 位对齐到 16bit 量程；L=nb0，R=nb1
    //    * 立体声：pcm = (左 + 右) >>> 1
    //-------------------------------------------------------------------------
    wire [7:0] nb0 = (dcnt == 4'd0) ? s_data : fb0;
    wire [7:0] nb1 = (dcnt == 4'd1) ? s_data : fb1;
    wire [7:0] nb2 = (dcnt == 4'd2) ? s_data : fb2;
    wire [7:0] nb3 = (dcnt == 4'd3) ? s_data : fb3;

    wire signed [15:0] p_left  = (bits == 16'd16) ? $signed({nb1, nb0})
                                                  : { (nb0 - 8'd128), 8'h00 };
    wire signed [15:0] p_right = (bits == 16'd16) ? $signed({nb3, nb2})
                                                  : { (nb1 - 8'd128), 8'h00 };
    wire signed [16:0] p_sum   = {p_left[15], p_left} + {p_right[15], p_right}; // 17bit 防溢出
    wire signed [15:0] p_now   = (channels <= 16'd1) ? p_left : p_sum[16:1];    // 单声道取左，立体声下混

    //-------------------------------------------------------------------------
    // 4) 主状态机
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st           <= S_RIFF;
            bcnt         <= 3'd0;
            idbuf        <= 32'd0;
            sz_be        <= 32'd0;
            chunk_size   <= 32'd0;
            chunk_left   <= 32'd0;
            fread        <= 32'd0;
            data_left    <= 32'd0;
            f_audiofmt   <= 16'd0;
            f_byterate   <= 32'd0;
            f_blockalign <= 16'd0;
            fb0          <= 8'd0;
            fb1          <= 8'd0;
            fb2          <= 8'd0;
            fb3          <= 8'd0;
            dcnt         <= 4'd0;
            bpf          <= 8'd0;
            bram_we      <= 1'b0;
            bram_addr    <= {AW{1'b0}};
            wr_ptr       <= {AW{1'b0}};
            bram_data    <= 16'd0;
            sample_count <= 32'd0;
            sample_rate  <= 32'd0;
            channels     <= 16'd0;
            bits         <= 16'd0;
            header_ok    <= 1'b0;
            load_done    <= 1'b0;
            load_active  <= 1'b0;
        end else begin
            bram_we <= 1'b0;              // 默认不写，只在需要时给 1 拍脉冲

            if (byte_take) begin
                case (st)

                //================== "RIFF" ==================
                S_RIFF: begin
                    idbuf <= {idbuf[23:0], s_data};
                    if (bcnt == 3'd3) begin
                        bcnt <= 3'd0;
                        // 拼齐 4 字节后比较；不符就留在本状态继续滑动(自对齐全)
                        if ({idbuf[23:0], s_data} == M_RIFF)
                            st <= S_RSIZE;
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                //================== 跳过 4 字节文件长度 ==================
                S_RSIZE: begin
                    if (bcnt == 3'd3) begin
                        bcnt <= 3'd0;
                        st   <= S_WAVE;
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                //================== "WAVE" ==================
                S_WAVE: begin
                    idbuf <= {idbuf[23:0], s_data};
                    if (bcnt == 3'd3) begin
                        bcnt <= 3'd0;
                        if ({idbuf[23:0], s_data} == M_WAVE)
                            st <= S_CID;         // 头部合法，开始读块
                        // 不符则继续留在这里滑动查找
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                //================== 读 4 字节"块 ID" ==================
                S_CID: begin
                    idbuf <= {idbuf[23:0], s_data};
                    if (bcnt == 3'd3) begin
                        bcnt <= 3'd0;
                        st   <= S_CSIZE;         // 接着读大小
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                //================== 读 4 字节"块大小"(小端) ==================
                S_CSIZE: begin
                    // 大端暂存，再翻转成小端得到真实值
                    sz_be <= {sz_be[23:0], s_data};
                    if (bcnt == 3'd3) begin
                        bcnt       <= 3'd0;
                        chunk_size <= {s_data, sz_be[7:0], sz_be[15:8], sz_be[23:16]};
                        // 上面这行：把 [b0 b1 b2 b3] 小端还原 = b0 | b1<<8 | b2<<16 | b3<<24
                        if (({s_data, sz_be[7:0], sz_be[15:8], sz_be[23:16]}) == 32'd0) begin
                            st <= S_CID;          // 空块，直接看下一个
                        end else if (idbuf == M_FMT) begin
                            fread <= 32'd0;
                            st    <= S_FMT;       // 进 fmt 解析
                        end else if (idbuf == M_DATA) begin
                            // 进入数据区：准备抓 PCM
                            data_left   <= {s_data, sz_be[7:0], sz_be[15:8], sz_be[23:16]};
                            bpf         <= channels[7:0] * {5'b0, bits[7:3]}; // 声道数 × (位宽/8)
                            fb0         <= 8'd0;
                            fb1         <= 8'd0;
                            fb2         <= 8'd0;
                            fb3         <= 8'd0;
                            dcnt        <= 4'd0;
                            wr_ptr      <= {AW{1'b0}};   // 从 0 开始写
                            load_active <= 1'b1;
                            header_ok   <= 1'b1;
                            st          <= S_DATA;
                        end else begin
                            // 其它块：整块跳过
                            chunk_left <= {s_data, sz_be[7:0], sz_be[15:8], sz_be[23:16]};
                            st         <= S_SKIP;
                        end
                    end else begin
                        bcnt <= bcnt + 3'd1;
                    end
                end

                //================== 解析 "fmt " 块（按偏移取字段）==================
                S_FMT: begin
                    case (fread)
                        32'd0:  f_audiofmt[7:0]     <= s_data;
                        32'd1:  f_audiofmt[15:8]    <= s_data;
                        32'd2:  channels[7:0]       <= s_data;
                        32'd3:  channels[15:8]      <= s_data;
                        32'd4:  sample_rate[7:0]    <= s_data;
                        32'd5:  sample_rate[15:8]   <= s_data;
                        32'd6:  sample_rate[23:16]  <= s_data;
                        32'd7:  sample_rate[31:24]  <= s_data;
                        32'd8:  f_byterate[7:0]     <= s_data;
                        32'd9:  f_byterate[15:8]    <= s_data;
                        32'd10: f_byterate[23:16]   <= s_data;
                        32'd11: f_byterate[31:24]   <= s_data;
                        32'd12: f_blockalign[7:0]   <= s_data;
                        32'd13: f_blockalign[15:8]  <= s_data;
                        32'd14: bits[7:0]           <= s_data;
                        32'd15: bits[15:8]          <= s_data;
                        default: ;              // 超过 16 字节的扩展字段忽略
                    endcase

                    fread <= fread + 32'd1;
                    if ((fread + 32'd1) == chunk_size) begin
                        // fmt 读完了：转去下一个块（奇数大小要跳 1 字节对齐）
                        fread     <= 32'd0;
                        bcnt      <= 3'd0;
                        header_ok <= 1'b1;
                        st        <= chunk_size[0] ? S_PAD : S_CID;
                    end else if ((fread + 32'd1) == 32'd16) begin
                        // fmt 超过 16 字节：前 16 字节够用了，剩下一律跳过
                        fread      <= 32'd0;
                        chunk_left <= chunk_size - 32'd16;
                        header_ok  <= 1'b1;
                        st         <= S_SKIP;
                    end
                end

                //================== 跳过整个块 ==================
                S_SKIP: begin
                    if (chunk_left <= 32'd1) begin
                        chunk_left <= 32'd0;
                        bcnt       <= 3'd0;
                        st         <= chunk_size[0] ? S_PAD : S_CID;  // 奇数补 1 字节对齐
                    end else begin
                        chunk_left <= chunk_left - 32'd1;
                    end
                end

                //================== 抓 PCM 采样 → 写 BRAM ==================
                S_DATA: begin
                    // 本拍字节先存进对应位置
                    case (dcnt)
                        4'd0: fb0 <= s_data;
                        4'd1: fb1 <= s_data;
                        4'd2: fb2 <= s_data;
                        4'd3: fb3 <= s_data;
                        default: ;
                    endcase
                    dcnt <= dcnt + 4'd1;

                    if (is_last) begin
                        // 一帧凑满 → 合成 1 个 16bit 采样并写入 BRAM
                        // 写地址 = 指针当前值；指针下一拍再前进，保证对得上
                        bram_we      <= 1'b1;
                        bram_addr    <= wr_ptr;
                        bram_data    <= p_now;
                        wr_ptr       <= (wr_ptr == {AW{1'b1}}) ? {AW{1'b0}} : (wr_ptr + 1'b1);
                        sample_count <= sample_count + 32'd1;
                        dcnt         <= 4'd0;
                    end

                    if (data_left <= 32'd1) begin
                        // data 块读完
                        data_left   <= 32'd0;
                        load_done   <= 1'b1;
                        load_active <= 1'b0;
                        st          <= S_DONE;
                    end else begin
                        data_left <= data_left - 32'd1;
                    end
                end

                //================== 块尾对齐填充（1 字节，丢弃）==================
                S_PAD: begin
                    bcnt <= 3'd0;
                    st   <= S_CID;
                end

                //================== 结束 ==================
                S_DONE: ;   // s_ready=0，不再消费

                default: st <= S_RIFF;
                endcase
            end
        end
    end

    // synthesis translate_off
    wire _unused = &{1'b0, f_audiofmt, f_byterate, f_blockalign, 1'b0};
    // synthesis translate_on

endmodule
