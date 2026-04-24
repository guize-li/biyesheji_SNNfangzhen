import numpy as np
import torch
import torch.nn as nn
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import snntorch as snn
from snntorch import surrogate
from snntorch import functional as SF
from sklearn.metrics import confusion_matrix
import seaborn as sns
import matplotlib
matplotlib.use('TkAgg')
import matplotlib.pyplot as plt

# ---------------------------------------------------------
# 1. 物理数据提取与二次多项式拟合
# ---------------------------------------------------------
I_data = np.array([6.5, 14.5, 18.0, 22.0, 26.0])
f_data = np.array([675.5, 686.0, 692.0, 696.5, 708.0])

# 使用 numpy polyfit 进行二次拟合 (degree=2)
coeffs = np.polyfit(I_data, f_data, 2)
poly_fit = np.poly1d(coeffs)

print(f"拟合多项式系数 [a, b, c]: {coeffs}")


# ---------------------------------------------------------
# 2. 自定义硬件感知编码器 (像素 -> 光强 -> 频率 -> Spikes)
# ---------------------------------------------------------
class OptoFrequencyEncoder:
    def __init__(self, I_min=6.5, I_max=26.0, dt=0.001, subtract_baseline=True):
        self.I_min = I_min
        self.I_max = I_max
        self.dt = dt
        self.subtract_baseline = subtract_baseline
        self.f_baseline = poly_fit(I_min)
        self.a, self.b, self.c = float(coeffs[0]), float(coeffs[1]), float(coeffs[2])

    def __call__(self, pixel_tensor, num_steps):
        # 1. 像素 (0-1) 映射到光强 (I_min - I_max)
        I_tensor = self.I_min + pixel_tensor * (self.I_max - self.I_min)

        # 2. 光强映射到物理频率 (完全在 GPU 上计算，避免与 CPU 的数据交换)
        f_tensor = self.a * I_tensor**2 + self.b * I_tensor + self.c

        # 3. 去基线
        if self.subtract_baseline:
            f_tensor = f_tensor - self.f_baseline

        scaling_factor = 10.0
        prob_tensor = (f_tensor * scaling_factor) * self.dt
        prob_tensor = torch.clamp(prob_tensor, 0.0, 1.0)  # 限制在 0-1 之间

        # 4. 生成时间步的泊松脉冲 (Time, Batch, Features)
        spike_train = torch.bernoulli(prob_tensor.unsqueeze(0).repeat(num_steps, 1, 1, 1, 1))
        return spike_train


# ---------------------------------------------------------
# 3. 三层 SNN 架构设计 & 仿真参数
# ---------------------------------------------------------
batch_size = 128
num_steps = 30
beta = 0.9375  # 膜电位衰减率
learning_rate = 1e-3
num_epochs = 50

# 数据加载
transform = transforms.Compose([transforms.ToTensor()])
mnist_train = datasets.MNIST("./data", train=True, download=True, transform=transform)
mnist_test = datasets.MNIST("./data", train=False, download=True, transform=transform)
train_loader = DataLoader(mnist_train, batch_size=batch_size, shuffle=True)
test_loader = DataLoader(mnist_test, batch_size=batch_size, shuffle=False)

# 替代梯度定义
spike_grad = surrogate.fast_sigmoid(slope=25)


# --- 替换原来的 Net 类 ---
class Net(nn.Module):
    def __init__(self):
        super().__init__()
        # 直接 784 到 10，无偏置
        self.fc1 = nn.Linear(28 * 28, 10, bias=False)
        self.lif1 = snn.Leaky(beta=beta, spike_grad=spike_grad)

    def quantize_16bit(self, weight):
        # Q4.12 定点数量化
        scale = 2 ** 12
        val = torch.round(weight * scale)
        val = torch.clamp(val, -32768, 32767)
        q_weight = val / scale
        return weight + (q_weight - weight).detach()

    def forward(self, x):
        mem1 = self.lif1.init_leaky()
        spk1_rec = []
        mem1_rec = []

        w1_q = self.quantize_16bit(self.fc1.weight)

        for step in range(num_steps):
            cur1 = torch.nn.functional.linear(x[step].view(x.shape[1], -1), w1_q)
            spk1, mem1 = self.lif1(cur1, mem1)

            spk1_rec.append(spk1)
            mem1_rec.append(mem1)

        return torch.stack(spk1_rec), torch.stack(mem1_rec)


device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
net = Net().to(device)
encoder = OptoFrequencyEncoder(subtract_baseline=True)

# ---------------------------------------------------------
# 4. 训练与测试循环
# ---------------------------------------------------------
optimizer = torch.optim.Adam(net.parameters(), lr=learning_rate, betas=(0.9, 0.999))
loss_fn = SF.ce_rate_loss()

print("\n--- 开始训练 ---")
for epoch in range(num_epochs):
    net.train()
    total_loss = 0
    for data, targets in train_loader:
        data = data.to(device)
        targets = targets.to(device)

        # 将像素应用物理曲线编码为脉冲序列
        spike_data = encoder(data, num_steps)

        spk_rec, _ = net(spike_data)
        loss = loss_fn(spk_rec, targets)

        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        total_loss += loss.item()

    print(f"Epoch {epoch + 1}/{num_epochs} - Loss: {total_loss / len(train_loader):.4f}")

# 测试与混淆矩阵生成
net.eval()
all_targets = []
all_preds = []

print("\n--- 开始测试 ---")
with torch.no_grad():
    for data, targets in test_loader:
        data = data.to(device)
        targets = targets.to(device)

        spike_data = encoder(data, num_steps)
        spk_rec, _ = net(spike_data)

        # 基于脉冲发放率进行预测
        _, idx = spk_rec.sum(dim=0).max(1)
        all_targets.extend(targets.cpu().numpy())
        all_preds.extend(idx.cpu().numpy())

accuracy = np.mean(np.array(all_targets) == np.array(all_preds))
print(f"**测试集准确率: {accuracy * 100:.2f}%**")

# 打印混淆矩阵
cm = confusion_matrix(all_targets, all_preds)
print("\n**混淆矩阵 (Confusion Matrix):**")
print(cm)

# 绘制带有具体数字的混淆矩阵
plt.figure(figsize=(10, 8))
sns.heatmap(cm, annot=True, fmt='d', cmap='Blues', xticklabels=np.arange(10), yticklabels=np.arange(10))
plt.title('Confusion Matrix')
plt.xlabel('Predicted Label')
plt.ylabel('True Label')
plt.savefig('confusion_matrix_2.png')
print("混淆矩阵图片已保存至 confusion_matrix_2.png")
# plt.show()  # 如果需要弹出窗口可以取消注释

# ---------------------------------------------------------
# 5. FPGA 纯整数硬件推理验证与 COE 文件导出
# ---------------------------------------------------------
print("\n--- 准备纯整数硬件推理验证与数据导出 ---")

# 截取前 100 张测试集图片
test_loader_100 = DataLoader(mnist_test, batch_size=100, shuffle=False)
data_100, targets_100 = next(iter(test_loader_100))
data_100 = data_100.to(device)
targets_100 = targets_100.numpy()

# 提取并生成 100 张图片的脉冲序列 (Time, Batch, Features)
with torch.no_grad():
    spike_data_100 = encoder(data_100, num_steps)  # shape: (30, 100, 1, 28, 28)
    spike_data_100 = spike_data_100.view(num_steps, 100, -1).cpu().numpy().astype(int) # shape: (30, 100, 784)

# 提取训练好的权重并进行 Q4.12 缩放为 16-bit 整数
scale = 2 ** 12
weights_float = net.fc1.weight.detach().cpu().numpy() # shape: (10, 784)
weights_int = np.clip(np.round(weights_float * scale), -32768, 32767).astype(np.int32)

# --- 纯整数硬件推理 ---
pure_int_preds = []
THRESHOLD = 4096

for i in range(100):
    mem = np.zeros(10, dtype=np.int32)
    spike_counts = np.zeros(10, dtype=np.int32)

    for t in range(num_steps):
        spikes_t = spike_data_100[t, i, :] # shape: (784,)
        # 突触电流累加
        current = np.dot(weights_int, spikes_t)

        # 相当于 V = V - (V >> 4) + W
        # 注意 Python 中的 >> 对于负数也是算术右移，与 Verilog 中 $signed 的 >>> 行为一致
        mem = mem - (mem >> 4) + current

        # 脉冲发放与重置 (V = V - Threshold)
        fired = mem >= THRESHOLD
        spike_counts += fired
        mem[fired] -= THRESHOLD

    pure_int_preds.append(np.argmax(spike_counts))

int_accuracy = np.mean(np.array(pure_int_preds) == targets_100)
print(f"**纯整数 16-bit 硬件推理准确率 (前 100 张图片): {int_accuracy * 100:.2f}%**")

# --- 导出 weights.coe ---
# BRAM 中每个地址存 160bit (10 * 16bit)。
# 对于 784 个输入神经元，相当于 784 行，每行放 10 个神经元对该输入的权重。
print("正在导出 weights.coe ...")
with open("weights.coe", "w") as f:
    f.write("memory_initialization_radix=16;\n")
    f.write("memory_initialization_vector=\n")
    for in_idx in range(784):
        hex_str = ""
        for out_idx in range(10):
            # 取出权重，转为 16-bit 无符号表示（便于写入 hex）
            w_val = weights_int[out_idx, in_idx]
            w_val_16 = w_val & 0xFFFF
            hex_str += f"{w_val_16:04X}"
        if in_idx == 783:
            f.write(f"{hex_str};\n")
        else:
            f.write(f"{hex_str},\n")
print("weights.coe 导出完成！")

# --- 导出 spikes.coe ---
# 100图 * 30步 * 784像素。
# 每个时间步 784 bit，按 16 bit 截断，共 49 个 16-bit 字。
print("正在导出 spikes.coe ...")
with open("spikes.coe", "w") as f:
    f.write("memory_initialization_radix=16;\n")
    f.write("memory_initialization_vector=\n")

    total_lines = 100 * 30 * 49
    current_line = 0

    for i in range(100):
        for t in range(num_steps):
            spikes_t = spike_data_100[t, i, :] # shape: (784,)
            for chunk_idx in range(49):
                # 每组 16 个 bit
                chunk = spikes_t[chunk_idx*16 : (chunk_idx+1)*16]
                # 将 16 个 bit 组合为一个数
                # 按照最高位在前或最低位在前需要根据你 verilog 逻辑一致，此处约定最高位为 chunk[0]
                val_16 = 0
                for bit in chunk:
                    val_16 = (val_16 << 1) | bit

                current_line += 1
                if current_line == total_lines:
                    f.write(f"{val_16:04X};\n")
                else:
                    f.write(f"{val_16:04X},\n")
print("spikes.coe 导出完成！(共导出 147000 行 16-bit 数据)")

# --- 导出 labels_100.txt ---
print("正在导出 labels_100.txt ...")
with open("labels_100.txt", "w") as f:
    for label in targets_100:
        f.write(f"{label}\n")
print("labels_100.txt 导出完成！")
