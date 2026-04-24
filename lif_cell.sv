module lif_cell #(
    // ================== 参数定义 ==================
    parameter WEIGHT_SUM_WIDTH = 20,           // 突触权重总和的位宽 (需与 synapse_compute 模块传过来的位宽匹配，例如15+$clog2(9) + 1 = 20)
    parameter MEM_WIDTH    = 24,           // 膜电位寄存器的位宽 (设大一点防溢出计算边界)
    parameter signed [MEM_WIDTH-1:0] V_TH = 24'd4096, // 激发脉冲的阈值电压 (Threshold)【QX.12定点数】
    parameter LEAK_SHIFT   = 3,            // 漏电位移位值：右移3位等效于衰减 当前电位的1/8 (即保留 7/8)
    parameter RESET_MODE   = 0             // 脉冲复位模式: 0为硬复位(直接归零), 1为软复位(电位减去阈值)
)(
    input  wire clk,
    input  wire rst_n,

    // ---------------- 接收端：与 synapse_compute 连接 ----------------
    // 接收上游传来的，属于本神经元的【所有突触权重加和最终结果】
    input  wire                            receive_valid, // 上游数据有效
    output wire                            receive_ready, // 神经元准备好接收数据
    input  wire signed [WEIGHT_SUM_WIDTH-1:0]  receive_weight_sum, // 输入加和

    // ---------------- 发送端：发往下一层级神经元 或 FIFO ----------------
    // 输出该神经元在这个时间步运算后，是否发放了脉冲 (Spike)
    output reg                             spike_valid,   // 发送数据有效
    input  wire                            spike_ready,   // 下游(FIFO)准备好接收
    output reg                             spike_out      // 神经元脉冲：1表示激发(Spike)，0表示只漏电未激发
);

    // 神经元最核心的状态寄存器：膜电位寄存器 (Membrane Potential)
    reg signed [MEM_WIDTH-1:0] mem_pot;

    // ----- 握手逻辑：流水电平控制 -----
    // 随时监测自身“有没有待发数据”或者“下游准备好拿走没”
    // 这是一个标准前级背压池判断
    assign receive_ready = (~spike_valid) || spike_ready;

    // ----- 组合逻辑：完整 LIF 运算过程 (Leaky Integrate and Fire) -----
    logic signed [MEM_WIDTH-1:0] next_mem_pot;
    logic signed [MEM_WIDTH-1:0] leaked_pot;//泄漏后的膜电位
    logic signed [MEM_WIDTH-1:0] integrated_pot;//积分后的膜电位
    logic                        is_spike;//是否触发脉冲

    always_comb begin
        // 1. 【Leaky 漏电】 
        // 采用算术右移 '>>>' 替代除法/乘法，这是硬件设计中极其常见的节约资源做法。
        // （必须用 >>> 而不是 >>，只有 >>> 才能保留带有负号的定点数的符号位不变）
        leaked_pot = mem_pot - (mem_pot >>> LEAK_SHIFT);

        // 2. 【Integrate 积分】
        // 漏电后的当前膜电位加上这一时刻上游发来的，该神经元所有突触加权之和
        integrated_pot = leaked_pot + receive_weight_sum;

        // 3. 【Fire & Reset 触发判断与复位】
        if (integrated_pot >= V_TH) begin
            is_spike = 1'b1;         // 超过阈值，发出放电脉冲！
            
            // 发射过后的膜电位复位动作
            if (RESET_MODE == 0) begin
                next_mem_pot = '0;   // [硬复位]：不管你超出阈值多少，发出脉冲后膜电位直接被抽干(归零)
            end else begin
                next_mem_pot = integrated_pot - V_TH; // [软复位]：扣除打出脉冲消耗掉的阈值电位，保留溢出残余
            end
        end else begin
            is_spike = 1'b0;         // 没到达阈值，继续憋大招
            
            // 【下限抑制保护】
            // 如果收到全是负向抑制性权重，膜电位可能会狂跌造成负向严重溢出。
            // 这里加入底线饱和池机制限制最低跌幅为 -V_TH （也可以根据需要改成 0 ）
            if (integrated_pot < -V_TH) begin
                next_mem_pot = -V_TH;
            end else begin
                next_mem_pot = integrated_pot;
            end
        end
    end

    // ----- 时序逻辑：将算好的膜电位置入神经元，刷新输出流水线 -----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_pot     <= '0;
            spike_valid <= 1'b0;
            spike_out   <= 1'b0;
        end else begin
            // 当且仅当我和上游完成了一次握手，说明当前时钟周期的脉冲注入了
            // 【关键点】只有发生握手（代表网络推进了一个实际的时间步），膜电位才会被允许更新！
            if (receive_valid && receive_ready) begin
                mem_pot     <= next_mem_pot; // 刷新我这只神经元身体里的膜电位
                spike_valid <= 1'b1;         // 告诉我下游："嘿，当前时间步我运算完了，来拿结果"
                spike_out   <= is_spike;     // 传1过去就是脉冲，传0过去就是没点亮
            end 
            // 如果上游没数据进来，且我的结果被下游取走了，就必须拉低有效信号防止重复重读
            else if (spike_valid && spike_ready) begin
                spike_valid <= 1'b0;
                spike_out   <= 1'b0;
            end
        end
    end

endmodule
