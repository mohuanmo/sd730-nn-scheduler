#!/usr/bin/env python3
"""
SD730 Neural Scheduler - Pure-Python Training Engine (v2.1.3)

零第三方依赖 (仅标准库), 用于没有 numpy 的环境 (如 py2droid 精简构建)。
与 train.py (numpy 版) 产出完全相同的模型文件格式 (awk 可读):

  Line 1: IN_DIM HID_DIM OUT_DIM
  W1 (10x16), b1 (16), W2 (16x2), b2 (2)

特征顺序与 bin/nn_infer.sh 严格一致:
  [cpu, gpu, temp, batt, charging, screen, threads, mem, hour, fg_duration]
  normalize scale: [100, 100, 100, 100, 1, 1, 100, 4096, 24, 300]

训练方式: 单样本 SGD (每样本一次更新), 比 batch 更适合纯 Python 实现。
纯 Python 速度约为 numpy 的 1/50, 夜间训练几分钟内可完成。
"""

import os, glob, sys, math, time, random
from datetime import datetime

MODDIR = "/data/adb/modules/sd730-scheduler"
DATA_DIR = f"{MODDIR}/data/collector"
MODEL_OUT = f"{MODDIR}/model/mlp_weights.txt"
CONFIG_DIR = f"{MODDIR}/config"
HABIT_FILE = f"{CONFIG_DIR}/nn_habit.db"
KEEP_DAYS = 5
MAX_TRAIN_SAMPLES = 5000   # 纯 Python 样本上限 (单样本 SGD, 足够 210 参数模型)
GRID_K_STEP = 0.1          # 稀疏网格步长 (纯 Python 无法用 np.arange, 网格加粗提速)
GRID_CAP_STEP = 0.1

# ============================================================
# 数据加载 (纯 Python)
# ============================================================
def cleanup_stale_files():
    now = time.time()
    removed = 0
    for f in glob.glob(f"{DATA_DIR}/*.raw"):
        try:
            if now - os.path.getmtime(f) > KEEP_DAYS * 86400:
                os.remove(f)
                removed += 1
        except OSError:
            continue
    if removed:
        print(f"[TRAIN-P] Cleaned {removed} stale data file(s)")

def _time_weighted_sample(file_data, n_target, decay=0.9):
    """按天分层 + 时间衰减加权抽样 (v2.1.7), 纯标准库实现"""
    import random as _r
    n_files = len(file_data)
    sizes = [len(d) for d in file_data]
    weights = [decay ** (n_files - 1 - i) for i in range(n_files)]
    quotas = [0] * n_files
    remaining = n_target
    guard = 0
    while remaining > 0 and guard < 64:
        guard += 1
        active = [i for i in range(n_files) if quotas[i] < sizes[i]]
        if not active:
            break
        tw = sum(weights[i] for i in active)
        if tw <= 0:
            break
        added = 0
        for i in active:
            q = int(remaining * weights[i] / tw)
            add = min(q, sizes[i] - quotas[i])
            quotas[i] += add
            added += add
        remaining = n_target - sum(quotas)
        if added == 0:
            break
    out = []
    for i, d in enumerate(file_data):
        if quotas[i] <= 0:
            continue
        if len(d) <= quotas[i]:
            out.extend(d)
        else:
            rng = _r.Random(42 + i)
            out.extend(rng.sample(d, quotas[i]))
    return out

def load_raw(force=False):
    cleanup_stale_files()
    files = sorted(glob.glob(f"{DATA_DIR}/*.raw"))
    if not files:
        print("[TRAIN-P] No data.")
        return None
    files = files[-KEEP_DAYS:]
    # 逐文件读取, 保留"天"归属 (v2.1.7: 按天分层抽样需要)
    file_data = []
    for f in files:
        rows = []
        try:
            with open(f, "r") as fp:
                for line in fp:
                    parts = line.strip().split("|")
                    if len(parts) != 13:
                        continue
                    try:
                        rows.append([
                            float(parts[2]),   # cpu
                            float(parts[3]),   # gpu
                            float(parts[4]),   # temp
                            float(parts[5]),   # batt
                            float(parts[6]),   # charging
                            float(parts[7]),   # screen
                            float(parts[8]),   # threads
                            float(parts[9]),   # mem
                            float(parts[12]),  # hour
                            float(parts[11]),  # fg_duration
                        ])
                    except ValueError:
                        continue
        except OSError:
            continue
        if rows:
            file_data.append(rows)
    if not file_data:
        print("[TRAIN-P] No data.")
        return None
    total = sum(len(d) for d in file_data)
    if total < 100:
        if force:
            print(f"[TRAIN-P] 警告: 仅 {total} 条样本 (<100), 强制模式照常加载")
        else:
            print(f"[TRAIN-P] Insufficient: {total} < 100")
            return None
    if total > MAX_TRAIN_SAMPLES:
        data = _time_weighted_sample(file_data, MAX_TRAIN_SAMPLES)
        print(f"[TRAIN-P] Time-weighted sampling: {len(data)} from {total} rows "
              f"({len(file_data)} days, decay=0.9)")
    else:
        data = [row for d in file_data for row in d]
    return data

def normalize_row(row):
    scale = [100.0, 100.0, 100.0, 100.0, 1.0, 1.0, 100.0, 4096.0, 24.0, 300.0]
    x = [row[i] / scale[i] for i in range(10)]
    # fgdur/300 钳制到 [0,1], 与 nn_infer.sh x[10] 保持一致 (v2.1.4)
    if x[9] > 1.0:
        x[9] = 1.0
    return x

# ============================================================
# 标签生成 (稀疏网格搜索, 与 train.py score_k_cap 数学一致)
# ============================================================
def score_k_cap(cpu, gpu, temp, batt, chg, screen, k, cap):
    cpu_n = cpu / 100.0
    gpu_n = gpu / 100.0
    perf = cpu_n * gpu_n * k * 2.0
    power = k * 0.3
    if not chg:
        power += k * 0.2
    temp_penalty = 0.0
    if temp > 60:
        temp_penalty = ((temp - 60) / 40.0) * k * 2.0
    if temp > 70:
        temp_penalty += ((temp - 70) / 30.0) * k * 3.0
    screen_penalty = 0.0
    if screen < 0.5:
        screen_penalty = (k - 0.5) * 0.5
    cap_penalty = 0.0
    if cap > 1.2 and cpu_n < 0.5:
        cap_penalty = (cap - 1.2) * 0.3
    if cap < 0.8 and cpu_n > 0.7:
        cap_penalty = (0.8 - cap) * 0.3
    return perf - power - temp_penalty - screen_penalty - cap_penalty

def generate_labels(X_raw):
    k_grid = []
    k = 0.5
    while k <= 2.0001:
        k_grid.append(round(k, 2)); k += GRID_K_STEP
    cap_grid = []
    c = 0.5
    while c <= 1.5001:
        cap_grid.append(round(c, 2)); c += GRID_CAP_STEP
    labels = []
    for row in X_raw:
        cpu, gpu, temp, batt, chg, screen = row[0], row[1], row[2], row[3], row[4], row[5]
        best = -1e18
        best_k, best_cap = 1.0, 1.0
        for k in k_grid:
            for cap in cap_grid:
                s = score_k_cap(cpu, gpu, temp, batt, chg, screen, k, cap)
                if s > best:
                    best, best_k, best_cap = s, k, cap
        labels.append([(best_k - 0.5) / 1.5, (best_cap - 0.5) / 1.0])
    return labels

# ============================================================
# 纯 Python MLP (10->16->2, ReLU + sigmoid, 单样本 SGD)
# ============================================================
def sigmoid(z):
    if z >= 0:
        return 1.0 / (1.0 + math.exp(-z))
    e = math.exp(z)
    return e / (1.0 + e)

class PureMLP:
    def __init__(self, n_in=10, n_hid=16, n_out=2, seed=None):
        if seed is not None:
            random.seed(seed)
        scale = 0.1  # 小初始化: 防单样本/小 batch 梯度放大导致发散
        self.W1 = [[random.uniform(-scale, scale) for _ in range(n_hid)] for _ in range(n_in)]
        self.b1 = [0.0] * n_hid
        self.W2 = [[random.uniform(-scale, scale) for _ in range(n_out)] for _ in range(n_hid)]
        self.b2 = [0.0] * n_out
        self.n_in, self.n_hid, self.n_out = n_in, n_hid, n_out

    def predict(self, x):
        """返回 (k, cap) 原始概率 [0,1] 对"""
        h = []
        for j in range(self.n_hid):
            z = self.b1[j]
            for i in range(self.n_in):
                z += x[i] * self.W1[i][j]
            h.append(z if z > 0 else 0.0)
        out = []
        for k in range(self.n_out):
            z = self.b2[k]
            for j in range(self.n_hid):
                z += h[j] * self.W2[j][k]
            out.append(sigmoid(z))
        return out

    def train(self, X, Y, epochs=60, lr=0.05, batch_size=32):
        """mini-batch SGD (纯 Python): 每样本前向+反向累积梯度, 每 batch 更新一次.
        batch 平均梯度比单样本 SGD 稳定得多, 与 numpy 版 (batch=128) 收敛行为一致."""
        n = len(X)
        t0 = time.time()
        for e in range(epochs):
            # 每 epoch 打乱
            order = list(range(n))
            random.shuffle(order)
            for start in range(0, n, batch_size):
                batch = order[start:start + batch_size]
                m = len(batch)
                # 累积梯度
                gW1 = [[0.0] * self.n_hid for _ in range(self.n_in)]
                gb1 = [0.0] * self.n_hid
                gW2 = [[0.0] * self.n_out for _ in range(self.n_hid)]
                gb2 = [0.0] * self.n_out
                for bi in batch:
                    xi, yi = X[bi], Y[bi]
                    # forward
                    h = []
                    for j in range(self.n_hid):
                        z = self.b1[j]
                        for i in range(self.n_in):
                            z += xi[i] * self.W1[i][j]
                        h.append(z if z > 0 else 0.0)
                    a2 = []
                    for k in range(self.n_out):
                        z = self.b2[k]
                        for j in range(self.n_hid):
                            z += h[j] * self.W2[j][k]
                        a2.append(sigmoid(z))
                    # backward (累积)
                    for k in range(self.n_out):
                        d2 = (a2[k] - yi[k]) / m
                        for j in range(self.n_hid):
                            gW2[j][k] += d2 * h[j]
                        gb2[k] += d2
                    for j in range(self.n_hid):
                        d1 = 0.0
                        for k in range(self.n_out):
                            d1 += (a2[k] - yi[k]) * self.W2[j][k]
                        d1 = d1 * (1.0 if h[j] > 0 else 0.0) / m
                        for i in range(self.n_in):
                            gW1[i][j] += d1 * xi[i]
                        gb1[j] += d1
                # 更新
                for i in range(self.n_in):
                    for j in range(self.n_hid):
                        self.W1[i][j] -= lr * gW1[i][j]
                for j in range(self.n_hid):
                    self.b1[j] -= lr * gb1[j]
                for j in range(self.n_hid):
                    for k in range(self.n_out):
                        self.W2[j][k] -= lr * gW2[j][k]
                for k in range(self.n_out):
                    self.b2[k] -= lr * gb2[k]
            if e % 10 == 0 or e == epochs - 1:
                loss = self.bce_loss(X, Y)
                print(f"  Epoch {e:3d}: loss={loss:.4f}  ({time.time()-t0:.0f}s elapsed)")

    def bce_loss(self, X, Y):
        total = 0.0
        eps = 1e-8
        for xi, yi in zip(X, Y):
            p = self.predict(xi)
            for k in range(self.n_out):
                y = yi[k]
                total -= y * math.log(p[k] + eps) + (1 - y) * math.log(1 - p[k] + eps)
        return total / len(X)

    def export_for_awk(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # 原子写 (v2.1.4): 先写临时文件再 os.replace, 避免 nn_infer.sh 读到半写模型
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(f"{self.n_in} {self.n_hid} {self.n_out}\n")
            for i in range(self.n_in):
                f.write(" ".join(f"{v:.8f}" for v in self.W1[i]) + "\n")
            f.write(" ".join(f"{v:.8f}" for v in self.b1) + "\n")
            for j in range(self.n_hid):
                f.write(" ".join(f"{v:.8f}" for v in self.W2[j]) + "\n")
            f.write(" ".join(f"{v:.8f}" for v in self.b2) + "\n")
        os.replace(tmp, path)
        print(f"[TRAIN-P] Exported: {path}")
        total = self.n_in * self.n_hid + self.n_hid + self.n_hid * self.n_out + self.n_out
        print(f"[TRAIN-P] Params: {total} floats (awk-compatible)")

# ============================================================
# 训练环境安全门控 (v2.1.4): 充电 + 温度
# ============================================================
def check_deep_standby():
    """深度待机: 充电 + 息屏 + 无前台 (纯标准库实现)"""
    import subprocess as _sp
    screen_on, has_fg, charging = True, True, False
    try:
        r = _sp.run(["dumpsys", "power"], capture_output=True, text=True, timeout=5)
        screen_on = "mWakefulness=Awake" in r.stdout or "Display Power: state=ON" in r.stdout
    except Exception:
        pass
    try:
        r = _sp.run(["dumpsys", "activity", "activities"], capture_output=True, text=True, timeout=5)
        seg = r.stdout.split("mResumedActivity")
        has_fg = len(seg) > 1 and "android" not in seg[1].split("\n")[0]
    except Exception:
        pass
    try:
        with open("/sys/class/power_supply/battery/status", "r") as f:
            charging = "Charging" in f.read()
    except OSError:
        pass
    is_standby = (not screen_on) and (not has_fg) and charging
    return is_standby, {"screen_on": screen_on, "has_fg": has_fg, "charging": charging}

def get_device_temp():
    """读取设备当前最高温度 (°C)。失败返回 0 (视为未知, 不阻断训练)。

    修复(v3.1.1): 旧实现取所有 thermal_zone*/temp 原始值最大值再 //1000,
    会把非温度传感器误判成高温而错误阻断(强制)训练:
      - lmh-dcvs-* (限频管理) 在部分机型恒报 75000 -> 误判 75°C
      - ibat/vbat/bcl (电流/电压/限流)、soc (电量%) 数值根本不是温度
      - *-step / *-lowf / *-max-step 是调频档位, 不是温度
    新实现: 只统计真正的温度传感器 (type 以 -tz/-usr 结尾, 或含 therm,
    或 type 为 battery/bms), 单位归一化 (毫摄氏度/十分之一度/摄氏度),
    合理范围 [10,90]°C 过滤。全部无效时回退读电池温度。
    """
    best = 0.0
    for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*/temp")):
        zdir = os.path.dirname(z)
        typ = ""
        try:
            with open(f"{zdir}/type", "r") as f:
                typ = f.read().strip().lower()
        except OSError:
            pass
        # 只认真正的温度传感器, 排除 lmh-dcvs/ibat/vbat/bcl/soc/step/lowf 等
        if not (typ.endswith("-tz") or typ.endswith("-usr")
                or "therm" in typ or typ in ("battery", "bms")):
            continue
        try:
            with open(z, "r") as f:
                v = int(f.read().strip())
        except (ValueError, OSError):
            continue
        if v <= 0:
            continue
        # 单位推断: 毫摄氏度 (主流, 如 48000=48°C) / 十分之一度 / 摄氏度
        if 10000 <= v <= 150000:
            c = v / 1000.0
        elif 100 <= v <= 1500:
            c = v / 10.0
        elif 10 <= v <= 150:
            c = float(v)
        else:
            continue
        if 10.0 <= c <= 90.0:
            best = max(best, c)
    if best <= 0:
        # 回退: 电池温度 (多数设备为十分之一度, 部分为毫摄氏度)
        try:
            with open("/sys/class/power_supply/battery/temp", "r") as f:
                v = int(f.read().strip())
            best = v / 10.0 if 100 <= v <= 1500 else v / 1000.0
        except (OSError, ValueError):
            pass
    return best

def get_train_max_temp():
    try:
        with open(f"{CONFIG_DIR}/nn.conf", "r") as f:
            for line in f:
                if line.startswith("nn_train_max_temp="):
                    v = float(line.split("=", 1)[1].strip())
                    if 30 <= v <= 90:
                        return v
    except (OSError, ValueError):
        pass
    return 55.0

# ============================================================
def main():
    # 实时日志 (v3.1.1): 经 sh 管道调用时 python stdout 默认块缓冲, 会导致
    # 训练日志攒到结束才一次性输出; 这里强制行缓冲 + train.sh 加 -u 双保险
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    print("=" * 70)
    print("SD730 Neural Scheduler - Pure-Python Training (no numpy)")
    print("=" * 70)

    # --force: 主动判断后立即训练 (v2.1.4), 跳过深度待机硬性要求
    force = "--force" in sys.argv
    if force:
        print("[!] FORCE TRAIN (user triggered)")
        print("    ✓ 强制模式: 跳过 屏幕/前台/充电/样本量 检查; 温度仅保留 85°C 绝对安全上限")
    max_temp = get_train_max_temp()
    HARD_TEMP_CEIL = 85.0

    print("\n[1] Deep standby check (requires CHARGING + screen off + no FG)...")
    if force:
        print("    ✓ skipped (force mode)")
    else:
        is_standby, details = check_deep_standby()
        print(f"    Screen: {details['screen_on']}, FG: {details['has_fg']}, Charging: {details['charging']}")
        if not is_standby:
            print("    ✗ NOT deep standby -> skip training (或使用 sd730-scheduler --nn-train-now)")
            sys.exit(0)
        print("    ✓ Deep standby OK")

    print("\n[2] Temperature gate...")
    temp_now = get_device_temp()
    if temp_now >= 10:
        if temp_now > HARD_TEMP_CEIL:
            print(f"    ✗ {temp_now:.0f}C > {HARD_TEMP_CEIL:.0f}C 绝对安全上限 -> skip training (防物理损坏)")
            sys.exit(0)
        if temp_now > max_temp:
            if force:
                print(f"    ! 警告: {temp_now:.0f}C > 常规上限 {max_temp:.0f}C, 强制模式继续训练")
            else:
                print(f"    ✗ {temp_now:.0f}C > limit {max_temp:.0f}C -> skip training")
                sys.exit(0)
        else:
            print(f"    ✓ {temp_now:.0f}C <= {max_temp:.0f}C (nn_train_max_temp)")
    else:
        print(f"    ? temperature sensor unavailable ({temp_now}), proceeding")

    print("\n[3] Loading data (pure python)...")
    X_raw = load_raw(force=force)
    if X_raw is None:
        sys.exit(1)
    print(f"    Samples: {len(X_raw)}")
    if len(X_raw) < 500:
        if force:
            print(f"    ! 警告: 仅 {len(X_raw)} 条样本 (<500), 强制模式照常训练; 样本过少模型易过拟合/质量差")
        else:
            print(f"    ! Skip: {len(X_raw)} < 500")
            sys.exit(0)

    print("\n[4] Generating labels (sparse grid search)...")
    t0 = time.time()
    Y = generate_labels(X_raw)
    print(f"    Done in {time.time()-t0:.0f}s")

    X = [normalize_row(r) for r in X_raw]

    # 训练/验证划分 (90/10)
    random.seed(42)
    idx = list(range(len(X)))
    random.shuffle(idx)
    n_tr = int(len(idx) * 0.9)
    tr_idx, te_idx = idx[:n_tr], idx[n_tr:]
    X_tr = [X[i] for i in tr_idx]
    Y_tr = [Y[i] for i in tr_idx]
    X_te = [X[i] for i in te_idx]
    Y_te = [Y[i] for i in te_idx]
    print(f"    Train: {len(X_tr)}, Val: {len(X_te)}")

    print("\n[5] Training PureMLP (10->16->2, mini-batch SGD)...")
    mlp = PureMLP(n_in=10, n_hid=16, n_out=2, seed=42)
    # 训练中温度监控 (v2.1.4): 每 10 epochs 检查, 超限提前停止且不覆盖旧模型
    aborted = False
    for e in range(60):
        order = list(range(len(X_tr)))
        random.shuffle(order)
        for start in range(0, len(X_tr), 32):
            batch = order[start:start + 32]
            m = len(batch)
            gW1 = [[0.0] * mlp.n_hid for _ in range(mlp.n_in)]
            gb1 = [0.0] * mlp.n_hid
            gW2 = [[0.0] * mlp.n_out for _ in range(mlp.n_hid)]
            gb2 = [0.0] * mlp.n_out
            for bi in batch:
                xi, yi = X_tr[bi], Y_tr[bi]
                h = []
                for j in range(mlp.n_hid):
                    z = mlp.b1[j]
                    for i in range(mlp.n_in):
                        z += xi[i] * mlp.W1[i][j]
                    h.append(z if z > 0 else 0.0)
                a2 = []
                for k in range(mlp.n_out):
                    z = mlp.b2[k]
                    for j in range(mlp.n_hid):
                        z += h[j] * mlp.W2[j][k]
                    a2.append(sigmoid(z))
                for k in range(mlp.n_out):
                    d2 = (a2[k] - yi[k]) / m
                    for j in range(mlp.n_hid):
                        gW2[j][k] += d2 * h[j]
                    gb2[k] += d2
                for j in range(mlp.n_hid):
                    d1 = 0.0
                    for k in range(mlp.n_out):
                        d1 += (a2[k] - yi[k]) * mlp.W2[j][k]
                    d1 = d1 * (1.0 if h[j] > 0 else 0.0) / m
                    for i in range(mlp.n_in):
                        gW1[i][j] += d1 * xi[i]
                    gb1[j] += d1
            for i in range(mlp.n_in):
                for j in range(mlp.n_hid):
                    mlp.W1[i][j] -= 0.05 * gW1[i][j]
            for j in range(mlp.n_hid):
                mlp.b1[j] -= 0.05 * gb1[j]
            for j in range(mlp.n_hid):
                for k in range(mlp.n_out):
                    mlp.W2[j][k] -= 0.05 * gW2[j][k]
            for k in range(mlp.n_out):
                mlp.b2[k] -= 0.05 * gb2[k]
        if e % 10 == 0 or e == 59:
            print(f"  Epoch {e:3d}: loss={mlp.bce_loss(X_tr, Y_tr):.4f}")
        if e % 10 == 9 and e != 59:
            t = get_device_temp()
            if t >= 10:
                if t > HARD_TEMP_CEIL:
                    print(f"  ! {t:.0f}C > {HARD_TEMP_CEIL:.0f}C 绝对安全上限 at epoch {e} -> ABORT (keep old model)")
                    aborted = True
                    break
                if t > max_temp and not force:
                    print(f"  ! {t:.0f}C > {max_temp:.0f}C at epoch {e} -> ABORT training (keep old model)")
                    aborted = True
                    break
                if t > max_temp:
                    print(f"  ! {t:.0f}C > {max_temp:.0f}C (强制模式继续)")
    if aborted:
        print("✗ Training aborted by temperature. Old model preserved.")
        sys.exit(1)
    val_loss = mlp.bce_loss(X_te, Y_te)
    print(f"\n[6] Val loss: {val_loss:.4f}")

    print("\n[7] Sample predictions:")
    for i in range(min(5, len(X_te))):
        raw = X_raw[te_idx[i]]
        p = mlp.predict(X_te[i])
        k = 0.5 + p[0] * 1.5
        cap = 0.5 + p[1] * 1.0
        # 修正打印: raw[5]=screen (raw[6] 是 threads)
        print(f"    cpu={raw[0]:5.1f}% temp={raw[2]:5.1f}C screen={raw[5]:.0f} -> k={k:.3f} cap={cap:.3f}")

    mlp.export_for_awk(MODEL_OUT)
    print("\n" + "=" * 70)
    print("✓ Done (pure python, no numpy required)")
    print("=" * 70)

if __name__ == "__main__":
    main()
