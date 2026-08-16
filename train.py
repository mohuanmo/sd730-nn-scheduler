#!/data/data/com.termux/files/usr/bin/python3
"""
SD730 Neural Scheduler v2.1 - Night Training Script
Features:
  - Default window 01:00-04:00, learns user habit
  - Deep standby detection (screen off + no FG app + charging)
  - Dual output: k (aggressiveness) + cap_ratio (elastic budget)
  - Feature order MUST stay aligned with bin/nn_infer.sh (v2.1.1):
      [cpu, gpu, temp, batt, charging, screen, threads, mem, hour, fg_duration]
      normalize scale: [100, 100, 100, 100, 1, 1, 100, 4096, 24, 300]
"""

import os, glob, sys, time, subprocess
from datetime import datetime
try:
    import numpy as np
except ImportError:
    print("=" * 60)
    print("[TRAIN] ERROR: numpy not available in this Python environment.")
    print("[TRAIN] 训练需要 numpy。可选方案:")
    print("[TRAIN]   - Termux:  pkg install python numpy")
    print("[TRAIN]   - py2droid: python3 -m pip install numpy (如无预编译 wheel 需改用 Termux)")
    print("[TRAIN] 在安装 numpy 之前, 调度器会保持纯规则模式 (nn_alpha=0) 正常运行, 不受影响。")
    print("=" * 60)
    sys.exit(1)

MODDIR = "/data/adb/modules/sd730-scheduler"
DATA_DIR = f"{MODDIR}/data/collector"
MODEL_OUT = f"{MODDIR}/model/mlp_weights.txt"
CONFIG_DIR = f"{MODDIR}/config"
HABIT_FILE = f"{CONFIG_DIR}/nn_habit.db"
KEEP_DAYS = 5          # 与 collector.sh 保持一致 (v2.1.6: 3 -> 5, 覆盖工作日+周末)
MAX_TRAIN_SAMPLES = 20000  # 训练样本上限: 防止数据积累过多时网格搜索/训练过慢 (v2.1.2)

def load_habit():
    if not os.path.exists(HABIT_FILE):
        return None, 0
    try:
        with open(HABIT_FILE, "r") as f:
            parts = f.read().strip().split("|")
            if len(parts) == 3:
                return int(parts[0]), int(parts[2])
    except:
        pass
    return None, 0

def save_habit(last_hour, count):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(HABIT_FILE, "w") as f:
        f.write(f"{last_hour}|learned|{count}\n")

def compute_last_active_hour():
    files = sorted(glob.glob(f"{DATA_DIR}/*.raw"))
    if not files:
        return 23
    hour_counts = [0] * 24
    for f in files[-3:]:
        with open(f, "r") as fp:
            for line in fp:
                parts = line.strip().split("|")
                if len(parts) >= 13:
                    try:
                        h = int(parts[12])
                        cpu = float(parts[2])
                        if cpu > 5:
                            hour_counts[h] += 1
                    except:
                        continue
    threshold = max(hour_counts) * 0.1 if max(hour_counts) > 0 else 0
    for h in range(23, -1, -1):
        if hour_counts[h] > threshold:
            return h
    return 23

def get_train_window():
    learned_h, count = load_habit()
    last_active = compute_last_active_hour()
    if learned_h is None:
        learned_h = last_active
        count = 1
    else:
        alpha = 0.3
        learned_h = int(alpha * last_active + (1 - alpha) * learned_h)
        count += 1
    save_habit(learned_h, count)
    if count >= 3:
        start = max(0, learned_h - 3)
        end = learned_h
        # 修正(v2.1.1): learned_h=0 时 start=end=0 为空窗口, 训练永不触发
        if start >= end:
            start, end = 1, 4
    else:
        start, end = 1, 4
    return start, end, learned_h, count

def check_deep_standby():
    try:
        result = subprocess.run(["dumpsys", "power"], capture_output=True, text=True, timeout=5)
        screen_on = "mWakefulness=Awake" in result.stdout or "Display Power: state=ON" in result.stdout
    except:
        screen_on = True
    try:
        result = subprocess.run(["dumpsys", "activity", "activities"], capture_output=True, text=True, timeout=5)
        has_fg = "mResumedActivity" in result.stdout and "android" not in result.stdout.split("mResumedActivity")[1].split("\n")[0]
    except:
        has_fg = True
    try:
        with open("/sys/class/power_supply/battery/status", "r") as f:
            charging = "Charging" in f.read()
    except:
        charging = False
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
    """从 nn.conf 读取训练温度上限 (nn_train_max_temp, 默认 55°C) (v2.1.4)"""
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

def cleanup_stale_files():
    """训练前兜底清理过期 .raw (v2.1.2): 即使 collector 未运行, 训练时也会清理"""
    import time as _t
    now = _t.time()
    removed = 0
    for f in glob.glob(f"{DATA_DIR}/*.raw"):
        try:
            age = now - os.path.getmtime(f)
            if age > KEEP_DAYS * 86400:
                os.remove(f)
                removed += 1
        except OSError:
            continue
    if removed:
        print(f"[TRAIN] Cleaned {removed} stale data file(s) (> {KEEP_DAYS}d)")

def _time_weighted_sample(file_data, n_target, decay=0.9):
    """按天分层 + 时间衰减加权抽样 (v2.1.7)

    问题: 均匀抽样时, 若最近 1-2 天数据量就达到上限, 前面几天的数据会被
         完全抽不到 → 模型丢失历史模式 (周末游戏 / 工作日办公差异)。
    方案: 按天配额, 每天至少保留代表性样本; 权重随时间轻微衰减
         (最近 1.0, 每往前一天 x0.9), 近期数据略多(学最新习惯)但老数据不丢。
    """
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
            out.append(d)
        else:
            rng = np.random.RandomState(42 + i)
            out.append(d[rng.choice(len(d), quotas[i], replace=False)])
    return np.concatenate(out)

def load_raw(force=False):
    cleanup_stale_files()
    files = sorted(glob.glob(f"{DATA_DIR}/*.raw"))
    if not files:
        print("[TRAIN] No data.")
        return None
    files = files[-KEEP_DAYS:]
    # 逐文件读取, 保留"天"归属 (v2.1.7: 按天分层抽样需要)
    file_data = []
    for f in files:
        rows = []
        with open(f, "r") as fp:
            for line in fp:
                parts = line.strip().split("|")
                if len(parts) == 13:
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
                    except:
                        continue
        if rows:
            file_data.append(np.array(rows, dtype=np.float32))
    if not file_data:
        print("[TRAIN] No data.")
        return None
    total = sum(len(d) for d in file_data)
    if total < 100:
        if force:
            print(f"[TRAIN] 警告: 仅 {total} 条样本 (<100), 强制模式照常加载")
        else:
            print(f"[TRAIN] Insufficient: {total} < 100")
            return None
    if total > MAX_TRAIN_SAMPLES:
        data = _time_weighted_sample(file_data, MAX_TRAIN_SAMPLES)
        n_days = len(file_data)
        per_day = [len(d) for d in file_data]
        print(f"[TRAIN] Time-weighted sampling: {len(data)} from {total} rows "
              f"({n_days} days, per-day={per_day}, decay=0.9)")
    else:
        data = np.concatenate(file_data)
    return data

def normalize(X):
    scale = np.array([100.0, 100.0, 100.0, 100.0, 1.0, 1.0, 100.0, 4096.0, 24.0, 300.0], dtype=np.float32)
    Xn = X / scale
    # fgdur/300 钳制到 [0,1], 与 nn_infer.sh x[10] 保持一致 (v2.1.4)
    Xn[:, 9] = np.minimum(Xn[:, 9], 1.0)
    return Xn

def score_k_cap(cpu, gpu, temp, batt, chg, screen, k, cap):
    cpu_n = cpu / 100.0
    gpu_n = gpu / 100.0

    # Performance
    perf = cpu_n * gpu_n * k * 2.0

    # Power
    power = k * 0.3
    if not chg:
        power += k * 0.2

    # Temperature
    temp_penalty = 0
    if temp > 60:
        temp_penalty = ((temp - 60) / 40.0) * k * 2.0
    if temp > 70:
        temp_penalty += ((temp - 70) / 30.0) * k * 3.0

    # Screen off
    screen_penalty = 0
    if screen < 0.5:
        screen_penalty = (k - 0.5) * 0.5

    # Cap ratio: higher cap allows more threads on big cores
    # But too high causes contention
    cap_penalty = 0
    if cap > 1.2 and cpu_n < 0.5:
        cap_penalty = (cap - 1.2) * 0.3  # Over-allocating when not needed
    if cap < 0.8 and cpu_n > 0.7:
        cap_penalty = (0.8 - cap) * 0.3  # Under-allocating when needed

    return perf - power - temp_penalty - screen_penalty - cap_penalty

def generate_labels(X_raw):
    labels = []
    for row in X_raw:
        cpu, gpu, temp, batt, chg, screen, threads, mem, hour, fgdur = row
        best_score = -1e9
        best_k, best_cap = 1.0, 1.0
        for k in np.arange(0.5, 2.01, 0.05):
            for cap in np.arange(0.5, 1.51, 0.05):
                s = score_k_cap(cpu, gpu, temp, batt, chg, screen, k, cap)
                if s > best_score:
                    best_score = s
                    best_k, best_cap = k, cap
        # Normalize for sigmoid
        norm_k = (best_k - 0.5) / 1.5
        norm_cap = (best_cap - 0.5) / 1.0
        labels.append([norm_k, norm_cap])
    return np.array(labels, dtype=np.float32)

class TinyMLP:
    def __init__(self, n_in=10, n_hid=16, n_out=2, seed=None):
        if seed is not None:
            np.random.seed(seed)
        self.W1 = np.random.randn(n_in, n_hid).astype(np.float32) * np.sqrt(2.0 / n_in)
        self.b1 = np.zeros(n_hid, dtype=np.float32)
        self.W2 = np.random.randn(n_hid, n_out).astype(np.float32) * np.sqrt(2.0 / n_hid)
        self.b2 = np.zeros(n_out, dtype=np.float32)
        self.n_in = n_in
        self.n_hid = n_hid
        self.n_out = n_out
        self.loss_history = []

    def forward(self, X):
        self.z1 = X @ self.W1 + self.b1
        self.a1 = np.maximum(self.z1, 0)
        self.z2 = self.a1 @ self.W2 + self.b2
        return 1.0 / (1.0 + np.exp(-self.z2))

    def train(self, X, Y, epochs=300, lr=0.05, batch_size=128):
        n = len(X)
        for e in range(epochs):
            idx = np.random.permutation(n)
            total_loss = 0.0
            for i in range(0, n, batch_size):
                batch_idx = idx[i:i+batch_size]
                xb = X[batch_idx]
                yb = Y[batch_idx]
                a2 = self.forward(xb)
                loss = -np.mean(np.sum(yb * np.log(a2 + 1e-8) + (1-yb) * np.log(1-a2 + 1e-8), axis=1))
                total_loss += loss * len(batch_idx)
                dz2 = (a2 - yb) / len(batch_idx)
                dW2 = self.a1.T @ dz2
                db2 = np.sum(dz2, axis=0)
                da1 = dz2 @ self.W2.T
                dz1 = da1 * (self.z1 > 0)
                dW1 = xb.T @ dz1
                db1 = np.sum(dz1, axis=0)
                self.W1 -= lr * dW1
                self.b1 -= lr * db1
                self.W2 -= lr * dW2
                self.b2 -= lr * db2
            avg_loss = total_loss / n
            self.loss_history.append(avg_loss)
            if e % 50 == 0 or e == epochs - 1:
                print(f"  Epoch {e:3d}: loss={avg_loss:.6f}")

    def export_for_awk(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # 原子写 (v2.1.4): 先写临时文件再 os.replace, 避免 nn_infer.sh 读到半写模型
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(f"{self.n_in} {self.n_hid} {self.n_out}\n")
            for i in range(self.n_in):
                f.write(" ".join(f"{v:.8f}" for v in self.W1[i]) + "\n")
            f.write(" ".join(f"{v:.8f}" for v in self.b1) + "\n")
            for i in range(self.n_hid):
                f.write(" ".join(f"{v:.8f}" for v in self.W2[i]) + "\n")
            f.write(" ".join(f"{v:.8f}" for v in self.b2) + "\n")
        os.replace(tmp, path)
        print(f"[TRAIN] Exported: {path}")
        total = self.n_in * self.n_hid + self.n_hid + self.n_hid * self.n_out + self.n_out
        print(f"[TRAIN] Params: {total} floats")

def main():
    # 实时日志 (v3.1.1): 经 sh 管道调用时 python stdout 默认块缓冲, 会导致
    # 训练日志攒到结束才一次性输出; 这里强制行缓冲 + train.sh 加 -u 双保险
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    print("=" * 70)
    print("SD730 Neural Scheduler v2.1 - Night Training")
    print("=" * 70)

    # --force: 主动判断后立即训练 (v2.1.4), 跳过深度待机硬性要求
    force = "--force" in sys.argv
    if force:
        print("[!] FORCE TRAIN (user triggered)")
        print("    ✓ 强制模式: 跳过 屏幕/前台/充电/样本量 检查; 温度仅保留 85°C 绝对安全上限")

    # 训练温度上限 (v2.1.4): 常规上限 nn_train_max_temp; 强制模式放宽到绝对安全上限 (v3.1.1)
    max_temp = get_train_max_temp()
    HARD_TEMP_CEIL = 85.0

    now = datetime.now()
    start_h, end_h, learned_h, count = get_train_window()
    print(f"\n[1] Window: {start_h:02d}:00-{end_h:02d}:00, learned last active: {learned_h}:00")

    print("\n[2] Deep standby check (requires CHARGING + screen off + no FG)...")
    if force:
        print("    ✓ skipped (force mode)")
    else:
        is_standby, details = check_deep_standby()
        print(f"    Screen: {details['screen_on']}, FG: {details['has_fg']}, Charging: {details['charging']}")
        # 修正(v2.1.4): 非 force 必须深度待机(充电+息屏+无前台)才允许训练, 防止边用边训/耗电发热
        if not is_standby:
            print("    ✗ NOT deep standby -> skip training.")
            print("      (充电中 + 息屏 + 无前台 才自动训练; 或使用 sd730-scheduler --nn-train-now 强制)")
            sys.exit(0)
        print("    ✓ Deep standby OK")

    print("\n[3] Temperature gate...")
    temp_now = get_device_temp()
    if temp_now >= 10:  # 传感器可用
        if temp_now > HARD_TEMP_CEIL:
            print(f"    ✗ {temp_now:.0f}C > {HARD_TEMP_CEIL:.0f}C 绝对安全上限 -> skip training (防物理损坏)")
            sys.exit(0)
        if temp_now > max_temp:
            if force:
                print(f"    ! 警告: {temp_now:.0f}C > 常规上限 {max_temp:.0f}C, 强制模式继续训练")
            else:
                print(f"    ✗ {temp_now:.0f}C > limit {max_temp:.0f}C -> skip training (防止高温下继续发热)")
                sys.exit(0)
        else:
            print(f"    ✓ {temp_now:.0f}C <= {max_temp:.0f}C (nn_train_max_temp)")
    else:
        print(f"    ? temperature sensor unavailable ({temp_now}), proceeding")

    print(f"\n[4] Loading data...")
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

    X = normalize(X_raw)
    Y = generate_labels(X_raw)

    # 修正(v2.1.1): 划分前 shuffle, 避免按时间顺序划分导致训练/测试分布漂移
    rng = np.random.RandomState(42)
    idx = rng.permutation(len(X))
    X, Y = X[idx], Y[idx]

    n_train = int(len(X) * 0.9)
    X_train, X_test = X[:n_train], X[n_train:]
    Y_train, Y_test = Y[:n_train], Y[n_train:]

    print(f"\n[5] Training TinyMLP (10 -> 16 -> 2)...")
    mlp = TinyMLP(n_in=10, n_hid=16, n_out=2, seed=42)
    # 训练中温度监控 (v2.1.4): 每 50 epochs 检查, 超限提前停止且不覆盖旧模型
    aborted = False
    for e in range(300):
        idxb = np.random.permutation(n_train)
        total_loss = 0.0
        for i in range(0, n_train, 128):
            batch_idx = idxb[i:i+128]
            xb, yb = X_train[batch_idx], Y_train[batch_idx]
            a2 = mlp.forward(xb)
            loss = -np.mean(np.sum(yb * np.log(a2 + 1e-8) + (1-yb) * np.log(1-a2 + 1e-8), axis=1))
            total_loss += loss * len(batch_idx)
            dz2 = (a2 - yb) / len(batch_idx)
            dW2 = mlp.a1.T @ dz2
            db2 = np.sum(dz2, axis=0)
            da1 = dz2 @ mlp.W2.T
            dz1 = da1 * (mlp.z1 > 0)
            dW1 = xb.T @ dz1
            db1 = np.sum(dz1, axis=0)
            mlp.W1 -= 0.05 * dW1
            mlp.b1 -= 0.05 * db1
            mlp.W2 -= 0.05 * dW2
            mlp.b2 -= 0.05 * db2
        avg_loss = total_loss / n_train
        mlp.loss_history.append(avg_loss)
        if e % 50 == 0 or e == 299:
            # 同时打印验证集 loss: train-val gap 过大 = 过拟合信号 (v2.1.6)
            vloss = -np.mean(np.sum(Y_test * np.log(mlp.forward(X_test) + 1e-8) +
                                    (1-Y_test) * np.log(1-mlp.forward(X_test) + 1e-8), axis=1))
            print(f"  Epoch {e:3d}: train={avg_loss:.6f}  val={vloss:.6f}  (gap={vloss-avg_loss:+.6f})")
        # 温度巡检 (v3.1.1): 强制模式仅保留绝对安全上限, 常规上限只拦截非 force
        if e % 50 == 49 and e != 299:
            t = get_device_temp()
            if t >= 10:
                if t > HARD_TEMP_CEIL:
                    print(f"  ! {t:.0f}C > {HARD_TEMP_CEIL:.0f}C 绝对安全上限 at epoch {e} -> ABORT training (keep old model)")
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

    pred = mlp.forward(X_test)
    val_loss = -np.mean(np.sum(Y_test * np.log(pred + 1e-8) + (1-Y_test) * np.log(1-pred + 1e-8), axis=1))
    print(f"\n[6] Val loss: {val_loss:.6f}")

    print(f"\n[7] Sample predictions:")
    for i in range(min(5, len(X_test))):
        raw = X_raw[n_train + i]
        p = pred[i]
        k = 0.5 + p[0] * 1.5
        cap = 0.5 + p[1] * 1.0
        # 修正打印: raw[5]=screen (raw[6] 是 threads) (v2.1.5)
        print(f"    cpu={raw[0]:5.1f}% temp={raw[2]:5.1f}C screen={raw[5]:.0f} -> k={k:.3f} cap={cap:.3f}")

    mlp.export_for_awk(MODEL_OUT)
    print("\n" + "=" * 70)
    print("✓ Done")
    print("=" * 70)

if __name__ == "__main__":
    main()
