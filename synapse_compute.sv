module synapse_compute #(
    parameter DATA_WIDTH = 784,
    parameter FIRST_LAYER_LIF_NUM = 10 
)(
    input  wire       clk,
    input  wire       rst_n,
    
    // 接收上游
    input  wire                  receive_valid,
    output reg                   receive_ready,
    input  wire [DATA_WIDTH-1:0] receive_data,

    // 发往下游
    output reg                   send_valid,
    input  wire                  send_ready,
    output reg signed [FIRST_LAYER_LIF_NUM - 1:0][19:0] send_data_weight_sum,

    // 与存放 Weights COE 的 BRAM 连接的接口：10*16 = 160bit
    output reg                   weight_bram_ena,
    output reg  [9:0]            weight_bram_addr, 
    input  wire [159:0]          weight_bram_dout
);

    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        SCAN      = 3'd1, // 寻找第i个发脉冲的节点发读请求
        WAIT_BRAM = 3'd2, // 等待一拍BRAM读的延迟
        ACCUM     = 3'd3, // 取走读出来的160bit,并且加给10个暂存器中
        DONE      = 3'd4
    } state_t;

    state_t state, next_state;
    
    reg [DATA_WIDTH-1:0] recv_buffer;
    reg [9:0]            scan_idx; // 扫描指针
    reg signed [19:0]    temp_sum [0:FIRST_LAYER_LIF_NUM-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (receive_valid && receive_ready) next_state = SCAN;
            end
            SCAN: begin
                if (scan_idx >= DATA_WIDTH) 
                    next_state = DONE;
                else if (recv_buffer[scan_idx] == 1'b1) 
                    next_state = WAIT_BRAM;
            end
            WAIT_BRAM: begin
                next_state = ACCUM;
            end
            ACCUM: begin
                next_state = SCAN; 
            end
            DONE: begin
                if (send_valid && send_ready)
                    next_state = IDLE;
            end
        endcase
    end

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receive_ready <= 1'b1;
            send_valid <= 1'b0;
            weight_bram_ena <= 1'b0;
            scan_idx <= '0;
            for (i = 0; i < FIRST_LAYER_LIF_NUM; i++) begin
                temp_sum[i] <= '0;
                send_data_weight_sum[i] <= '0;
            end
        end else begin
            // 默认准备操作
            weight_bram_ena <= 1'b0;

            case (state)
                IDLE: begin
                    receive_ready <= 1'b1;
                    send_valid <= 1'b0;
                    scan_idx <= '0;
                    for (i = 0; i < FIRST_LAYER_LIF_NUM; i++) begin
                        temp_sum[i] <= '0;
                    end
                    if (receive_valid && receive_ready) begin
                        recv_buffer <= receive_data;
                        receive_ready <= 1'b0; // 开始干活不允许外面发脉冲进来
                    end
                end

                SCAN: begin
                    if (scan_idx < DATA_WIDTH) begin
                        if (recv_buffer[scan_idx] == 1'b1) begin
                            weight_bram_ena <= 1'b1;
                            weight_bram_addr <= scan_idx;
                        end else begin
                            scan_idx <= scan_idx + 1; // 没脉冲跳过
                        end
                    end
                end

                WAIT_BRAM: begin
                    weight_bram_ena <= 1'b0; // 地址已经发送，等待单周期获取 BRAM 数据
                end

                ACCUM: begin
                    scan_idx <= scan_idx + 1; 

                    for (i = 0; i < FIRST_LAYER_LIF_NUM; i++) begin
                         // 已经修正为读取端序相反，通过 (FIRST_LAYER_LIF_NUM - 1 - i) 来匹配 Python COE 从左到右打印（MSB端存放第0个神经元的大端序问题）
                         temp_sum[i] <= temp_sum[i] + $signed(weight_bram_dout[((FIRST_LAYER_LIF_NUM - 1 - i) * 16) +: 16]);
                    end
                end

                DONE: begin
                    send_valid <= 1'b1;
                    for (i = 0; i < FIRST_LAYER_LIF_NUM; i++) begin
                        send_data_weight_sum[i] <= temp_sum[i];
                    end
                    if (send_valid && send_ready) begin
                        send_valid <= 1'b0;
                        receive_ready <= 1'b1; // 复位接口准备接收新的特征批次
                    end
                end
            endcase
        end
    end
endmodule