module lif_layer #(
    // ================== 参数定义 ==================
    parameter LIF_NUM          = 4,  // 本层神经元的数量 (需与 synapse_compute 里配对)
    //LIF_CELL 模块的参数
    parameter WEIGHT_SUM_WIDTH = 20, // 突触权重总和的位宽 (需与 synapse_compute 防溢出的位宽一样)
    parameter MEM_WIDTH        = 24, // 膜电位寄存器的位宽 (比突触和更宽，防累加溢出)
    parameter signed [MEM_WIDTH-1:0] V_TH = 24'd1000, // 触发脉冲的阈值
    parameter LEAK_SHIFT       = 4,  // 漏电右移倍率
    parameter RESET_MODE       = 1   // 复位模式(0硬复位, 1软复位)
)(
    input  wire clk,
    input  wire rst_n,

    // ---------------- 接收端：与 synapse_compute 握手并接数据 ----------------
    // 整个 LIF 神经元层的同一时刻 valid 接收信号，用于所有神经元的同步
    input  wire                            receive_valid,
    // 【汇总输出】：如果这 4 个神经元都说“随时恭候”，则对上游输出 receive_ready=1
    output wire                            receive_ready, 
    // 包含 4 个神经元的突触权重和数据总线 ( SystemVerilog 支持多维解包数组形式 )
    input  wire signed [LIF_NUM-1:0] [WEIGHT_SUM_WIDTH-1:0] receive_weight_sums,

    // ---------------- 发送端：将 4 个脉冲组装并发送到下一层或 FIFO ----------------
    // 【汇总输出】：如果此层所有的神经元同频处理完毕需要发脉冲，则 valid=1
    output wire                            send_valid,    
    // 假设下游有一个整体就绪的接盘信号
    input  wire                            send_ready,    
    // 打包好的 4 根脉冲线直接输出 (每根线代表对应神经元当周期的 Spike 触发结果)
    output wire [LIF_NUM-1:0]              send_spikes    
);

    // ================= 内部连线信号 =================
    // 这两个数组用来收集内部每个单独的 lif_cell 传出的握手状态
    wire [LIF_NUM-1:0] cell_synapse_ready; // 每个细胞各自报告的准备状态
    wire [LIF_NUM-1:0] cell_spike_valid;   // 每个细胞各自报告的脉冲计算完毕状态

    // ================= 握手逻辑：整层同频汇聚 =================
    // 汇聚逻辑(&)：必须等到阵列里所有单只神经元都变为了 ready，整个一层才对上游算作准备就绪（防止某一只发生卡顿现象）。
    assign receive_ready = &cell_synapse_ready; 
    
    // 同样的，必须等到阵列里的*所有*细胞都完成了该周期运算、准备好向外抛出结果时，这整个一层才通知下游“你的货齐了”
    assign send_valid = &cell_spike_valid;

    // ================= generate 并行例化 LIF 神经元阵列 =================
    // 利用 generate 语法，根据 LIF_NUM 动态批量生成、自动连接 4 个(甚至任意个) LIF_cell 模块
    genvar i;
    generate
        for (i = 0; i < LIF_NUM; i = i + 1) begin : lif_neurons_array
            lif_cell #(
                // 把外部参数传进每一个神经元
                .WEIGHT_SUM_WIDTH (WEIGHT_SUM_WIDTH),
                .MEM_WIDTH        (MEM_WIDTH),
                .V_TH             (V_TH),
                .LEAK_SHIFT       (LEAK_SHIFT),
                .RESET_MODE       (RESET_MODE)
            ) u_lif_cell (
                .clk                (clk),
                .rst_n              (rst_n),
                
                // 【接收端通道切片】
                // 因为并行同频，统一向单只神经元散发全局同频的 valid 信号
                .receive_valid      (receive_valid),           
                // 收集这只神经元的 ready 回复
                .receive_ready      (cell_synapse_ready[i]),  
                // 从上游长总线里，像切豆腐一样“按索引位”片出属于它的那部分私有权重和
                .receive_weight_sum (receive_weight_sums[i]), 
                
                // 【发送端通道组装】
                // 这只神经元报告其本身的处理 valid 是否已经完工，传给收集阵列
                .spike_valid        (cell_spike_valid[i]),
                // 下游 ready 信号向它们统一广播扩散
                .spike_ready        (send_ready),
                // 合并装订这只神经元的专属 1 bit 脉冲给总线输出组
                .spike_out          (send_spikes[i])
            );
        end
    endgenerate

endmodule
