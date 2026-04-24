module hand_fifo #(
    parameter DATA_WIDTH = 9, // 数据位宽（比如传脉冲ID，9位够表示1-9独热码）
    parameter DEPTH      = 9  // FIFO深度（最多存9个脉冲）
)(
    input  wire clk,
    input  wire rst_n,

    // ---------------- 输入端（上游写数据） ----------------
    input  wire                  receive_valid, // 上游说：我有有效数据
    output wire                  receive_ready, // FIFO说：我没满，可以接收
    input  wire [DATA_WIDTH-1:0] receive_data,  // 上游传来的数据

    // ---------------- 输出端（下游读数据） ----------------
    output wire                  send_valid, // FIFO说：我有数据可以给你
    input  wire                  send_ready, // 下游说：我空闲了，给我数据吧
    output wire [DATA_WIDTH-1:0] send_data   // 给下游的数据
);


    integer i; // 循环变量，放在模块作用域以避免综合器未命名块抛出非法静态变量定义错误
    // FIFO 内部存储器
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    
    // 读写指针和计数器
    reg [$clog2(DEPTH) - 1:0] receive_ptr, send_ptr;
    reg [$clog2(DEPTH):0] count;

    // 状态标志
    wire full  = (count == DEPTH);
    wire empty = (count == 0);

    // 握手信号连线：没满就能写，没空就能读
    assign receive_ready = ~full;  
    assign send_valid = ~empty; 
    assign send_data  = mem[send_ptr]; // 直接把队头数据挂在输出总线上

    // 发生成功握手的条件
    wire receive_en = receive_valid && receive_ready;
    wire send_en  = send_valid && send_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receive_ptr <= 0;
            send_ptr <= 0;
            count  <= 0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                mem[i] <= {DATA_WIDTH{1'b0}}; // 复位时清空FIFO
            end
        end else begin
            // 写操作
            if (receive_en) begin
                mem[receive_ptr] <= receive_data;
                receive_ptr <= (receive_ptr == DEPTH-1) ? 0 : receive_ptr + 1;
            end
            
            // 读操作
            if (send_en) begin
                send_ptr <= (send_ptr == DEPTH-1) ? 0 : send_ptr + 1;
            end
            
            // 更新计数器（同时读写时，数量不变）
            if (receive_en && !send_en)
                count <= count + 1;
            else if (!receive_en && send_en)
                count <= count - 1;
            else // 同时读写或都不读写，count保持不变
                count <= count;
        end
    end
endmodule
