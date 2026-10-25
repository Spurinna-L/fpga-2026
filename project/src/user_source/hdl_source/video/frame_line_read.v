`timescale 1ns/1ps
//=============================================================================
// frame_line_read.v — 按行读取 A/B 两个图片槽
//-----------------------------------------------------------------------------
// 每收到一次 line_toggle（video_clk 域，已带 line_num），就在 mem_clk 域
// 顺序发出 1280 个 App_rd_en：
//     前 640 个：A 槽 base_a + line_y*640
//     后 640 个：B 槽 base_b + line_y*640
// SDRAM 返回的 Sdr_rd_en 按返回顺序写入行缓冲：
//     ret_cnt[0..639]   -> A 缓冲，地址 ret_cnt[9:0]
//     ret_cnt[640..1279]-> B 缓冲，地址 (ret_cnt-640)[9:0]
// 写 bank = line_y[0]，与显示侧 pix_y[0] 乒乓对应。
//
// 为什么用返回计数而不是固定延时：
//   Sdr_rd_en 的实际延迟会随控制器状态变化；计满 1280 个返回脉冲再
//   宣布 line_done，才能保证 A/B 两行都真正落进 BRAM，杜绝行尾串道。
//
// 与后台扫描的关系：
//   sweep_busy=1 时不允许启动新的行读取；扫描停止后由 sweep 自身排空
//   12~16 拍，顶层才拉低 sweep_busy。
//=============================================================================
module frame_line_read #(
    parameter ADDR_BITS = 21
)(
    input  wire                 clk,            // ext_mem_clk = 125MHz
    input  wire                 rst,

    input  wire                 enable,         // display_valid（mem 域）
    input  wire                 Sdr_init_done,
    input  wire                 sweep_busy,     // 后台扫描占用中

    input  wire [20:0]          base_a,
    input  wire [20:0]          base_b,

    // 来自 video_clk 域的行请求（toggle + 行号）
    input  wire                 line_toggle,
    input  wire [9:0]           line_num,

    output reg                  line_busy,
    output reg                  line_done,
    output reg                  first_line_done,
    output reg                  last_line_done,

    // SDRAM 用户读接口
    output reg                  App_rd_en,
    output reg  [20:0]          App_rd_addr,
    input  wire                 Sdr_busy,
    input  wire                 Sdr_rd_en,
    input  wire [31:0]          Sdr_rd_dout,

    // 行缓冲写口（A/B 由 lb_sel 区分）
    output wire                 lb_we,
    output reg                  lb_bank,
    output wire [9:0]           lb_addr,
    output wire [23:0]          lb_data,
    output wire                 lb_sel
);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_ISSUE = 2'd1;
    localparam [1:0] S_WAIT  = 2'd2;

    localparam [10:0] WORDS_PER_LINE = 11'd640;
    localparam [10:0] WORDS_TOTAL    = 11'd1280;

    reg [1:0]   state;
    reg [10:0]  issue_cnt;
    reg [10:0]  ret_cnt;
    reg [9:0]   req_y;
    reg [20:0]  addr_a;
    reg [20:0]  addr_b;

    // line_toggle 跨到 125MHz 域，取第 2 级做边沿检测
    reg [2:0] tog_sync;
    wire      tog_pulse = tog_sync[2] ^ tog_sync[1];

    // 待处理行号（video 域给的 line_num 在 toggle 前后保持稳定）
    reg [9:0] pend_y;
    reg       pend_valid;

    // 行内偏移：line_y * 640 = (line_y << 9) + (line_y << 7)
    wire [18:0] pend_off = ({9'd0, pend_y} << 9) + ({11'd0, pend_y} << 7);

    wire start = (state == S_IDLE) && pend_valid && enable &&
                 Sdr_init_done && !sweep_busy;

    // 当前要发的地址：前 640 字 A，后 640 字 B
    wire [20:0] cur_addr = (issue_cnt < WORDS_PER_LINE)
                         ? (addr_a + {10'd0, issue_cnt[9:0]})
                         : (addr_b + {10'd0, (issue_cnt - WORDS_PER_LINE)});

    // 行缓冲写口：按 SDRAM 实际返回顺序落盘
    assign lb_we   = Sdr_rd_en && line_busy && (ret_cnt < WORDS_TOTAL);
    assign lb_addr = (ret_cnt >= WORDS_PER_LINE) ? (ret_cnt - WORDS_PER_LINE)
                                                 : ret_cnt[9:0];
    assign lb_sel  = (ret_cnt >= WORDS_PER_LINE);
    assign lb_data = Sdr_rd_dout[31:8];

    // line_toggle 同步与边沿
    always @(posedge clk or posedge rst) begin
        if (rst)
            tog_sync <= 3'b000;
        else
            tog_sync <= {tog_sync[1:0], line_toggle};
    end

    // 待处理请求：toggle 到了先锁行号；如果正在扫或正在读，等条件满足
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pend_y     <= 10'd0;
            pend_valid <= 1'b0;
        end else begin
            if (!enable) begin
                pend_valid <= 1'b0;
            end else if (tog_pulse) begin
                pend_y     <= line_num;
                pend_valid <= 1'b1;
            end else if (start) begin
                pend_valid <= 1'b0;
            end
        end
    end

    // 主状态机
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= S_IDLE;
            issue_cnt      <= 11'd0;
            req_y          <= 10'd0;
            addr_a         <= 21'd0;
            addr_b         <= 21'd0;
            line_busy      <= 1'b0;
            line_done      <= 1'b0;
            first_line_done <= 1'b0;
            last_line_done <= 1'b0;
            lb_bank        <= 1'b0;
        end else begin
            line_done      <= 1'b0;
            first_line_done <= 1'b0;
            last_line_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        req_y     <= pend_y;
                        addr_a    <= base_a + {2'd0, pend_off};
                        addr_b    <= base_b + {2'd0, pend_off};
                        issue_cnt <= 11'd0;
                        lb_bank   <= pend_y[0];
                        line_busy <= 1'b1;
                        state     <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    if (issue_cnt < WORDS_TOTAL)
                        issue_cnt <= issue_cnt + 11'd1;

                    if (issue_cnt == WORDS_TOTAL)
                        state <= S_WAIT;
                end

                S_WAIT: begin
                    if (ret_cnt == WORDS_TOTAL) begin
                        line_busy <= 1'b0;
                        line_done <= 1'b1;
                        if (req_y == 10'd0)
                            first_line_done <= 1'b1;
                        if (req_y == 10'd479)
                            last_line_done <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // App_rd_en / addr 同拍寄存；与 M1 的 frame_fifo_read 一样，读命令连续发出，
    // 不因 Sdr_busy 中断，避免一条 1280 字的行被拆成不连续的小段。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            App_rd_en   <= 1'b0;
            App_rd_addr <= 21'd0;
        end else if ((state == S_ISSUE) && (issue_cnt < WORDS_TOTAL)) begin
            App_rd_en   <= 1'b1;
            App_rd_addr <= cur_addr;
        end else begin
            App_rd_en <= 1'b0;
        end
    end

    // 返回计数：1280 个 Sdr_rd_en 到齐后 line_done
    always @(posedge clk or posedge rst) begin
        if (rst)
            ret_cnt <= 11'd0;
        else if (start)
            ret_cnt <= 11'd0;
        else if (line_busy && Sdr_rd_en && (ret_cnt < WORDS_TOTAL))
            ret_cnt <= ret_cnt + 11'd1;
    end

endmodule
