module top #(
    parameter DATA_WIDTH = 784,
    parameter DEPTH      = 4, 
    parameter FIRST_LAYER_LIF_NUM = 10,
    parameter TIME_STEP_WIN = 30   
)(
    input  wire clk,
    input  wire rst_n,

    // 导出的 BRAM IP接口，供你在Vivado BD或者外置 IP中手工连入 COE
    // 或者交给 Testbench 使用模拟 BRAM 驱动
    output wire                   spike_bram_ena,
    output wire [17:0]            spike_bram_addr,
    input  wire [15:0]            spike_bram_dout,

    output wire                   weight_bram_ena,
    output wire [9:0]             weight_bram_addr,
    input  wire [159:0]           weight_bram_dout,

    // 给外部 Testbench 计算准确率用的测试接口
    output wire                                     out_result_valid,
    output wire   [$clog2(FIRST_LAYER_LIF_NUM)-1:0] out_result_id
);

// ====================== 1. BRAM SPIKE 自动读取流水线 ======================
wire                   sr_valid;
wire                   sr_ready;
wire [DATA_WIDTH-1:0]  sr_data;

bram_spike_reader #(
    .DATA_WIDTH   (DATA_WIDTH)
) u_bram_spike_reader (
    .clk              (clk),
    .rst_n            (rst_n),
    .spike_bram_ena   (spike_bram_ena),
    .spike_bram_addr  (spike_bram_addr),
    .spike_bram_dout  (spike_bram_dout),
    .timestep_valid   (sr_valid),
    .timestep_ready   (sr_ready),
    .timestep_data    (sr_data)
);

// ====================== 2. 第一级 FIFO ======================
wire                   fifo1_valid;
wire                   fifo1_ready;
wire [DATA_WIDTH-1:0]  fifo1_data;

hand_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
) u_fifo_1 (
    .clk           (clk),
    .rst_n         (rst_n),
    .receive_valid (sr_valid),
    .receive_ready (sr_ready),
    .receive_data  (sr_data),
    .send_valid    (fifo1_valid),
    .send_ready    (fifo1_ready),
    .send_data     (fifo1_data)
);

// ====================== 3. FSM 多步串行突触计算 ======================
wire        syn_valid;
wire        syn_ready;
wire signed [FIRST_LAYER_LIF_NUM-1:0][19:0] syn_weight_sums; 

synapse_compute #(
    .DATA_WIDTH          (DATA_WIDTH),
    .FIRST_LAYER_LIF_NUM (FIRST_LAYER_LIF_NUM)
) u_synapse_compute (
    .clk                  (clk),
    .rst_n                (rst_n),
    .receive_valid        (fifo1_valid),
    .receive_ready        (fifo1_ready),
    .receive_data         (fifo1_data),
    .send_valid           (syn_valid),
    .send_ready           (syn_ready),
    .send_data_weight_sum (syn_weight_sums),
    // 权重 BRAM 接口
    .weight_bram_ena      (weight_bram_ena),
    .weight_bram_addr     (weight_bram_addr),
    .weight_bram_dout     (weight_bram_dout)
);

// ====================== 4. 第二级 FIFO ======================
// 注意：10个神经元 * 20bit = 200bit 位宽
wire        fifo2_valid;
wire        fifo2_ready;
wire [200-1:0] fifo2_data_flat;

hand_fifo #(
    .DATA_WIDTH (200), 
    .DEPTH      (DEPTH)   
) u_fifo_2 (
    .clk           (clk),
    .rst_n         (rst_n),
    .receive_valid (syn_valid),
    .receive_ready (syn_ready),
    .receive_data  (syn_weight_sums), 
    .send_valid    (fifo2_valid),
    .send_ready    (fifo2_ready),
    .send_data     (fifo2_data_flat)
);

// ====================== 5. LIF 神经元层 ======================
wire        lif_valid;
wire        lif_ready;
wire [FIRST_LAYER_LIF_NUM-1:0]  lif_spikes;

lif_layer #(
    .LIF_NUM          (FIRST_LAYER_LIF_NUM),
    .WEIGHT_SUM_WIDTH (20),
    .MEM_WIDTH        (24),
    .V_TH             (24'd4096), // 注意：Python中的 threshold 是 4096 (12位小数)
    .LEAK_SHIFT       (4),
    .RESET_MODE       (0)
) u_lif_layer_1 (
    .clk                 (clk),
    .rst_n               (rst_n),
    .receive_valid       (fifo2_valid),
    .receive_ready       (fifo2_ready),
    .receive_weight_sums (fifo2_data_flat), 
    .send_valid          (lif_valid),
    .send_ready          (lif_ready),
    .send_spikes         (lif_spikes)
);

// ====================== 6. 30步计数判定窗口 ======================
output_logic #(
    .LIF_NUM       (FIRST_LAYER_LIF_NUM),
    .TIME_STEP_WIN (TIME_STEP_WIN) 
) u_output_logic (
    .clk            (clk),
    .rst_n          (rst_n),
    .receive_valid  (lif_valid),
    .receive_ready  (lif_ready),
    .receive_spikes (lif_spikes),
    .result_valid   (out_result_valid),
    .result_id      (out_result_id)
);

endmodule