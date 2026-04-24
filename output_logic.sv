module output_logic #(
    parameter LIF_NUM       = 10,  
    parameter TIME_STEP_WIN = 30   
)(
    input  wire clk,
    input  wire rst_n,

    input  wire                   receive_valid,
    output wire                   receive_ready,
    input  wire [LIF_NUM-1:0]     receive_spikes,

    // 输出识别结果记录脉冲（在第30通触发一个周期的验证）
    output reg                        result_valid,
    output reg  [$clog2(LIF_NUM)-1:0] result_id
);

    reg [$clog2(TIME_STEP_WIN):0] event_cnt;
    reg [15:0] spike_counts [0:LIF_NUM-1]; 

    integer i;
    reg [15:0] max_val;
    reg [$clog2(LIF_NUM)-1:0] max_index;

    assign receive_ready = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_cnt <= '0;
            result_valid  <= 1'b0;
            result_id     <= '0;
            for (i = 0; i < LIF_NUM; i = i + 1) begin
                spike_counts[i] <= '0;
            end
        end else begin
            result_valid <= 1'b0; 
            
            if (receive_valid && receive_ready) begin
                // 收到脉冲了就加和
                for (i = 0; i < LIF_NUM; i = i + 1) begin
                    if (receive_spikes[i]) spike_counts[i] <= spike_counts[i] + 1;
                end
                
                // 窗口判定
                if (event_cnt == TIME_STEP_WIN - 1) begin
                    max_val   = spike_counts[0] + receive_spikes[0];
                    max_index = 0;
                    
                    for (i = 1; i < LIF_NUM; i = i + 1) begin
                        if ((spike_counts[i] + receive_spikes[i]) > max_val) begin
                            max_val   = spike_counts[i] + receive_spikes[i];
                            max_index = i;
                        end
                    end
                    
                    result_valid <= 1'b1;
                    result_id    <= max_index;
                    
                    // 清空开启新图片
                    event_cnt <= '0;
                    for (i = 0; i < LIF_NUM; i = i + 1) begin
                        spike_counts[i] <= '0;
                    end
                end else begin
                    event_cnt <= event_cnt + 1;
                end
            end
        end
    end
endmodule
