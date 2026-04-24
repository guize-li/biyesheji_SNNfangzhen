module bram_spike_reader #(
    parameter DATA_WIDTH = 784
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // 与存放 Spikes COE 的 BRAM 连接的接口
    output reg                   spike_bram_ena,
    output reg  [17:0]           spike_bram_addr, // 最大到 147000，使用需要至少 18bit
    input  wire [15:0]           spike_bram_dout,

    // 发往后级脉冲计算模块，传输一次时间步合成完毕的 784 位脉宽
    output reg                   timestep_valid,
    input  wire                  timestep_ready,
    output reg  [DATA_WIDTH-1:0] timestep_data
);

    // ================= FSM 状态机定义 =================
    typedef enum logic [2:0] {
        IDLE        = 3'd0,
        REQ_READ    = 3'd1, // 发送读BRAM地址
        WAIT_BRAM   = 3'd2, // 等待BRAM取数据的一拍延迟
        WAIT_DATA   = 3'd3, // 等待BRAM数据并拼接
        DONE        = 3'd4  // 拼装发送给网络握手
    } state_t;

    state_t state, next_state;

    // ================= 内部计数器 =================
    reg [5:0]  chunk_cnt;            // 这个图片的当前步，已经读了多少块 (0 ~ 48, 49*16 = 784)
    reg [17:0] current_base_addr;    // 纪录总图片与时间步进度，最高 147000
    reg [DATA_WIDTH-1:0] build_data; // 移位积攒器

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                // 当下游空闲时才开始发新图片周期
                if (timestep_ready) next_state = REQ_READ;
            end
            REQ_READ: begin
                next_state = WAIT_BRAM;
            end
            WAIT_BRAM: begin
                next_state = WAIT_DATA;
            end
            WAIT_DATA: begin
                if (chunk_cnt == 6'd48)
                    next_state = DONE;
                else
                    next_state = REQ_READ;
            end
            DONE: begin
                if (timestep_valid && timestep_ready)
                    next_state = IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chunk_cnt <= '0;
            current_base_addr <= '0;
            build_data <= '0;
            spike_bram_ena <= 1'b0;
            timestep_valid <= 1'b0;
            timestep_data <= '0;
        end else begin
            case (state)
                IDLE: begin
                    chunk_cnt <= '0;
                    timestep_valid <= 1'b0;
                end

                REQ_READ: begin
                    spike_bram_ena <= 1'b1;
                    spike_bram_addr <= current_base_addr;
                end

                WAIT_BRAM: begin
                    spike_bram_ena <= 1'b0; // 撤销使能，等数据出来
                end

                WAIT_DATA: begin
                    current_base_addr <= current_base_addr + 1;
                    
                    // 将读到的16位组装到对应的高位偏移位置，并且对大小端问题做翻转匹配
                    build_data[(chunk_cnt * 16) +: 16] <= {spike_bram_dout[0], spike_bram_dout[1], spike_bram_dout[2], spike_bram_dout[3], spike_bram_dout[4], spike_bram_dout[5], spike_bram_dout[6], spike_bram_dout[7], spike_bram_dout[8], spike_bram_dout[9], spike_bram_dout[10], spike_bram_dout[11], spike_bram_dout[12], spike_bram_dout[13], spike_bram_dout[14], spike_bram_dout[15]};
                    chunk_cnt <= chunk_cnt + 1;
                end

                DONE: begin
                    // 如果读满147000位（说明100张图验证完成），将其卷位至首位继续测试或停留
                    if (current_base_addr >= 18'd147000)
                         current_base_addr <= '0;

                    timestep_data <= build_data;
                    timestep_valid <= 1'b1;
                    if (timestep_valid && timestep_ready) begin
                        timestep_valid <= 1'b0;
                    end
                end
            endcase
        end
    end

endmodule