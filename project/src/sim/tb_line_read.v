`timescale 1ns/1ps
//=============================================================================
// tb_line_read.v — frame_line_read 单元测试
//   检查：A/B 地址序列、1280 个返回、lb_sel/lb_addr/lb_bank、line_done
//=============================================================================
module tb_line_read;

    reg clk = 0;
    always #4 clk = ~clk;          // 125MHz

    reg rst = 1;
    reg enable = 0;
    reg sdr_init_done = 0;
    reg sweep_busy = 0;
    reg [20:0] base_a = 21'd0;
    reg [20:0] base_b = 21'd307200;

    reg line_toggle = 0;
    reg [9:0] line_num = 0;

    wire line_busy, line_done, last_line_done;
    wire app_rd_en;
    wire [20:0] app_rd_addr;
    reg sdr_busy = 0;
    reg sdr_rd_en = 0;
    reg [31:0] sdr_rd_dout = 0;

    wire lb_we, lb_bank, lb_sel;
    wire [9:0] lb_addr;
    wire [23:0] lb_data;

    frame_line_read dut (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .Sdr_init_done(sdr_init_done),
        .sweep_busy(sweep_busy),
        .base_a(base_a),
        .base_b(base_b),
        .line_toggle(line_toggle),
        .line_num(line_num),
        .line_busy(line_busy),
        .line_done(line_done),
        .last_line_done(last_line_done),
        .App_rd_en(app_rd_en),
        .App_rd_addr(app_rd_addr),
        .Sdr_busy(sdr_busy),
        .Sdr_rd_en(sdr_rd_en),
        .Sdr_rd_dout(sdr_rd_dout),
        .lb_we(lb_we),
        .lb_bank(lb_bank),
        .lb_addr(lb_addr),
        .lb_data(lb_data),
        .lb_sel(lb_sel)
    );

    //-------------------------------------------------------------------------
    // SDRAM 读延迟模型：App_rd_en 后 10 拍返回 Sdr_rd_en + 数据
    //-------------------------------------------------------------------------
    reg [10:0] pv;
    reg [20:0] pa [0:10];
    integer i;
    initial begin
        pv = 0;
        for (i = 0; i <= 10; i = i + 1) pa[i] = 0;
    end

    always @(posedge clk) begin
        for (i = 10; i > 0; i = i - 1)
            pa[i] <= pa[i-1];
        pa[0] <= app_rd_addr;
        pv <= {pv[9:0], app_rd_en};

        sdr_rd_en   <= pv[10];
        sdr_rd_dout <= {8'h00, pa[10][7:0], pa[10][15:8], 8'h5A};
    end

    //-------------------------------------------------------------------------
    // 检查
    //-------------------------------------------------------------------------
    integer errs = 0;
    integer rd_cnt = 0;
    integer wr_cnt = 0;
    integer a_cnt = 0, b_cnt = 0;
    integer exp_addr = 0;

    always @(posedge clk) begin
        if (app_rd_en) begin
            if (rd_cnt < 640)
                exp_addr = base_a + 5*640 + rd_cnt;
            else
                exp_addr = base_b + 5*640 + (rd_cnt - 640);
            if (app_rd_addr !== exp_addr[20:0]) begin
                $display("ERR addr rd_cnt=%0d got=%0d exp=%0d", rd_cnt, app_rd_addr, exp_addr);
                errs = errs + 1;
            end
            rd_cnt = rd_cnt + 1;
        end

        if (lb_we) begin
            wr_cnt = wr_cnt + 1;
            if (lb_bank !== 1'b1) begin
                $display("ERR bank=%b exp=1", lb_bank); errs = errs + 1;
            end
            if (wr_cnt <= 640) begin
                if (lb_sel !== 1'b0) begin $display("ERR sel A=%b", lb_sel); errs=errs+1; end
                if (lb_addr !== ((wr_cnt-1) & 10'h3FF)) begin $display("ERR aaddr %0d", lb_addr); errs=errs+1; end
            end else begin
                if (lb_sel !== 1'b1) begin $display("ERR sel B=%b", lb_sel); errs=errs+1; end
                if (lb_addr !== ((wr_cnt-641) & 10'h3FF)) begin $display("ERR baddr %0d", lb_addr); errs=errs+1; end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 激励
    //-------------------------------------------------------------------------
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);
        enable = 1;
        sdr_init_done = 1;
        repeat (2) @(posedge clk);

        line_num = 10'd5;
        @(posedge clk); line_toggle <= 1'b1;
        // 保持为 1：line_toggle 是“每行翻转”的电平，翻回去就是下一行请求

        // 等待 line_done（最多 5000 拍）
        begin : wait_done
            repeat (5000) begin
                @(posedge clk);
                #1;
                if (line_done) disable wait_done;
            end
            $display("ERR timeout waiting line_done");
            errs = errs + 1;
        end

        repeat (5) @(posedge clk);
        #1;
        if (rd_cnt != 1280) begin $display("ERR rd_cnt=%0d", rd_cnt); errs=errs+1; end
        if (wr_cnt != 1280) begin $display("ERR wr_cnt=%0d", wr_cnt); errs=errs+1; end
        if (line_busy) begin $display("ERR line_busy still high"); errs=errs+1; end
        if (last_line_done) begin $display("ERR last_line_done for line 5"); errs=errs+1; end

        if (errs == 0)
            $display("TB_LINE_READ PASS (rd=%0d wr=%0d)", rd_cnt, wr_cnt);
        else
            $display("TB_LINE_READ FAIL errs=%0d", errs);
        $finish;
    end

endmodule
