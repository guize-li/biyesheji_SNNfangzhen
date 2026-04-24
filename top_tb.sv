`timescale 1ns/1ps

module tb_top();

    reg clk;
    reg rst_n;

    // DUT 接口
    wire        spike_bram_ena;
    wire [17:0] spike_bram_addr;
    reg  [15:0] spike_bram_dout;

    wire        weight_bram_ena;
    wire [9:0]  weight_bram_addr;
    reg [159:0] weight_bram_dout;

    wire        out_result_valid;
    wire [3:0]  out_result_id;

    // 例化顶层模块
    top u_top (
        .clk              (clk),
        .rst_n            (rst_n),
        .spike_bram_ena   (spike_bram_ena),
        .spike_bram_addr  (spike_bram_addr),
        .spike_bram_dout  (spike_bram_dout),
        .weight_bram_ena  (weight_bram_ena),
        .weight_bram_addr (weight_bram_addr),
        .weight_bram_dout (weight_bram_dout),
        .out_result_valid (out_result_valid),
        .out_result_id    (out_result_id)
    );

    // =========== 模拟 BRAM 动作 ===========
    // 定义大数组并在 initial 块中装载对应的 coe 内容
    reg [15:0]  spike_mem [0:146999]; // 100图*30步*49
    reg [159:0] weight_mem [0:783];   // 784宽

    initial begin
        // 使用 $readmemh 把你通过 python 跑出的16进制 coe 加载进内存用于模拟
        // 你用的是纯HEX，只要去掉coe文件头上两行描述声明即可直接加载
        $readmemh("spikes.txt", spike_mem); 
        $readmemh("weights.txt", weight_mem); 
    end

    // 充当 IP 核动作
    always @(posedge clk) begin
        if (spike_bram_ena)  spike_bram_dout <= spike_mem[spike_bram_addr];
        if (weight_bram_ena) weight_bram_dout <= weight_mem[weight_bram_addr];
    end

    // =========== 自动化精度校准与测试 ===========
    integer expected_labels [0:99]; // 读取 python 给我们的期望值
    integer total_tests = 0;
    integer correct_preds = 0;

    initial begin
        // 读取 python 生成的真值标签数组
        $readmemh("labels_100.txt", expected_labels); 
        clk = 0;
        rst_n = 0;
        #100;
        rst_n = 1;
    end

    always #10 clk = ~clk; // 100MHz 频率仿真推算

    always @(posedge clk) begin
        if (out_result_valid) begin // 一旦 SNN 处理足30次时间步算出图，触发比对
            $display("Image[%0d] Done! SNN Acc: %d | True Label: %d", 
                      total_tests, out_result_id, expected_labels[total_tests]);

            if (out_result_id == expected_labels[total_tests]) begin
                correct_preds = correct_preds + 1;
            end

            total_tests = total_tests + 1;

            if (total_tests == 100) begin
                $display("----------------------------------------");
                $display("  [All 100 Test Images Processed] ");
                $display("  Accuracy: %0d / 100", correct_preds);
                $display("----------------------------------------");
                $finish;
            end
        end
    end

endmodule