import numpy as np
import torch
import torch.nn as nn
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import snntorch as snn
from snntorch import surrogate
from snntorch import functional as SF
from sklearn.metrics import confusion_matrix
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
beta = 0.95  # 膜电位衰减率
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


# 三层网络: 784(输入) -> 128(隐层) -> 10(输出)
class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(28 * 28, 128)
        self.lif1 = snn.Leaky(beta=beta, spike_grad=spike_grad)
        self.fc2 = nn.Linear(128, 10)
        self.lif2 = snn.Leaky(beta=beta, spike_grad=spike_grad)

    def forward(self, x):
        mem1 = self.lif1.init_leaky()
        mem2 = self.lif2.init_leaky()

        spk2_rec = []
        mem2_rec = []

        for step in range(num_steps):
            cur1 = self.fc1(x[step].view(x.shape[1], -1))
            spk1, mem1 = self.lif1(cur1, mem1)
            cur2 = self.fc2(spk1)
            spk2, mem2 = self.lif2(cur2, mem2)

            spk2_rec.append(spk2)
            mem2_rec.append(mem2)

        return torch.stack(spk2_rec), torch.stack(mem2_rec)


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

plt.matshow(cm, cmap=plt.cm.Blues)
plt.colorbar()

thresh = cm.max() / 2.
for i in range(cm.shape[0]):
    for j in range(cm.shape[1]):
        plt.text(j, i, format(cm[i, j], 'd'),
                 ha="center", va="center",
                 color="white" if cm[i, j] > thresh else "black")

plt.title("Confusion Matrix", pad=20)
plt.ylabel("True label")
plt.xlabel("Predicted label")
plt.savefig("confusion_matrix.png")
try:
    plt.show()
except AttributeError:
    print("PyCharm SciView display failed. The confusion matrix has been saved as 'confusion_matrix.png'.")
