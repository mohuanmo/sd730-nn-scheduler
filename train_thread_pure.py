#!/usr/bin/env python3
"""
SD730 Neural Scheduler v3.0 - Thread-level Training, PURE PYTHON engine (v3.1.1)
零第三方依赖 (仅标准库), 与 train_thread.py (numpy 版) 数学/导出格式完全一致,
用于没有 numpy 的环境 (如 py2droid 精简构建 / 只能装 Python 3.14 的设备)。

数据: data/collector/YYYYMMDD.traw
  ts|pkg|聚合10|fn|favg|fvar|fzero|t1name|t1cpu|...|t6name|t6cpu
标签: 帧时间方差驱动 (帧率反馈)
  有效帧<10 或 0帧比例>30%      -> 跳过该样本 (帧率不可靠)
  帧时间 <= 1.05*16.67ms(60fps) -> 跑满, 标签 0 (已最优)
  流畅度 smooth=1-clamp(fvar/25,0,1) >= 0.8 -> 标签 0 (不需绑)
  卡顿 (smooth<0.5)             -> 高负载线程标签高 (该绑)
  中间                           -> 线性过渡

架构: 场景编码器(25->10) + 线程打分器(10+21->8->1), 联合训练
输出: model/mlp_v3_enc.txt + model/mlp_v3_scr.txt (awk 可读, 与 numpy 版一致)

与 numpy 版的差异 (仅性能取舍, 数学一致):
  - epochs 200 -> 60 (纯 Python 约慢 50 倍, 手机夜间几分钟内完成)
  - 样本上限 12000 -> 3000 (防止纯 Python 训练过慢)
"""
import os, glob, sys, time, random, math
from datetime import datetime

MODDIR = "/data/adb/modules/sd730-scheduler"
DATA_DIR = f"{MODDIR}/data/collector"
ENC_OUT = f"{MODDIR}/model/mlp_v3_enc.txt"
SCR_OUT = f"{MODDIR}/model/mlp_v3_scr.txt"
KEEP_DAYS = 5
MAX_SAMPLES = 3000        # 场景样本上限 (每组 6 线程); numpy 版为 12000
EPOCHS = 60               # numpy 版为 200; 纯 Python 降 epoch 保证手机可完成
FPS_CAP_MS = 1000.0/60    # 16.67ms

# ============ 12 类线程语义 (与 collector.sh thread_type 一致) ============
THREAD_TYPE = {
    "RenderThread": 0, "GLThread": 0, "UnityRender": 0, "SurfaceFlinger": 0, "GrWorker": 0,
    "GpuThread": 1,
    "HwBinder": 2, "Binder": 2,
    "main": 3, "ui": 3, "UiThread": 3,
    "AudioThread": 4, "AudioTrack": 4, "AudioFlinger": 4,
    "CodecThread": 5, "VideoDecoder": 5, "MediaCodec": 5,
    "Netd": 6, "OkHttp": 6,
    "SQLite": 7,
    "GC": 8, "Finalizer": 8, "HeapTaskDaemon": 8, "ReferenceQueue": 8, "Daemon": 8,
    "Jit": 9, "Compiler": 9, "dex2oat": 9,
    "Signal Catcher": 10, "JDWP": 10,
}
def thread_type_of(name):
    for pat, t in THREAD_TYPE.items():
        if name.startswith(pat) or pat in name:
            return t
    # 通配规则 (与 collector 一致)
    if name.startswith("GPU"): return 1
    if name.startswith("binder"): return 2
    if name.startswith("OMX") or name.startswith("NuPlayer"): return 5
    if name.startswith("Socket") or name.startswith("DNS"): return 6
    if name.startswith("DB-"): return 7
    if name.startswith("Jit") or name.startswith("Compiler"): return 9
    if name.startswith("Perf") or name.startswith("Sys"): return 10
    return 11

def str_hash8(s, bits=8):
    """与 shell str_hash8 一致: h=(h*31+c)&0xFFFFFFFF"""
    h = 0
    for ch in s.encode():
        h = (h * 31 + ch) & 0xFFFFFFFF
    return [float((h >> i) & 1) for i in range(bits)]

def onehot(cat, n):
    v = [0.0]*n; v[cat] = 1.0; return v

def app_category(pkg):
    p = pkg.lower()
    for pat in ("tmgp", "mihoyo", "netease", "game", "honor", "sgame"):
        if pat in p: return 0
    for pat in ("aweme", "douyin", "bilibili", "youtube", "video", "huoshan"):
        if pat in p: return 1
    for pat in ("tencent.mm", "weibo", "qq", "telegram", "whatsapp", "dingtalk"):
        if pat in p: return 2
    for pat in ("browser", "chrome", "firefox", "quark"):
        if pat in p: return 3
    for pat in ("autonavi", "baidu.map", "maps", "navigation"):
        if pat in p: return 4
    return 5

# ============ 数据加载 (.traw) ============
def load_traw():
    files = sorted(glob.glob(f"{DATA_DIR}/*.traw"))
    if not files:
        print("[TRAIN-TP] No .traw data (collector v3 sampling not running?)")
        return None
    files = files[-KEEP_DAYS:]
    file_data = []   # 每文件一个样本列表, 用于按天分层抽样
    for f in files:
        samples = []
        try:
            with open(f, "r") as fp:
                for line in fp:
                    parts = line.strip().split("|")
                    if len(parts) < 16:
                        continue
                    try:
                        ts, pkg = int(parts[0]), parts[1]
                        agg = [float(x) for x in parts[2:12]]
                        fn, favg, fvar, fzero = (int(parts[12]), float(parts[13]),
                                                 float(parts[14]), float(parts[15]))
                        threads = []
                        for k in range(6):
                            nm, cpu = parts[16+k*2], float(parts[17+k*2])
                            if nm and nm != "none":
                                threads.append((nm, cpu))
                        samples.append(dict(ts=ts, pkg=pkg, agg=agg, fn=fn,
                                            favg=favg, fvar=fvar, fzero=fzero, threads=threads))
                    except (ValueError, IndexError):
                        continue
        except OSError:
            continue
        if samples:
            file_data.append(samples)
    if not file_data:
        print("[TRAIN-TP] No valid .traw rows")
        return None
    # 时间衰减分层抽样 (与 v2 一致)
    if sum(len(d) for d in file_data) > MAX_SAMPLES:
        n_files = len(file_data)
        weights = [0.9 ** (n_files - 1 - i) for i in range(n_files)]
        sizes = [len(d) for d in file_data]
        quotas = [0]*n_files
        remaining = MAX_SAMPLES
        guard = 0
        while remaining > 0 and guard < 64:
            guard += 1
            active = [i for i in range(n_files) if quotas[i] < sizes[i]]
            if not active: break
            tw = sum(weights[i] for i in active)
            if tw <= 0: break
            added = 0
            for i in active:
                q = int(remaining * weights[i] / tw)
                add = min(q, sizes[i] - quotas[i])
                quotas[i] += add; added += add
            remaining = MAX_SAMPLES - sum(quotas)
            if added == 0: break
        out = []
        for i, d in enumerate(file_data):
            if quotas[i] <= 0: continue
            if len(d) <= quotas[i]:
                out.extend(d)
            else:
                rng = random.Random(42 + i)
                out.extend(rng.sample(d, quotas[i]))
        print(f"[TRAIN-TP] Time-weighted sampling: {len(out)} from {sum(sizes)} rows ({n_files} days)")
        return out
    return [s for d in file_data for s in d]

# ============ 特征与标签 ============
def build_dataset(samples):
    """返回 Xs(n,25), Xt(n,6,46), Yt(n,6,1), M(n,6) 有效标志 (纯列表)"""
    Xs, Xt, Yt, M = [], [], [], []
    for s in samples:
        agg = s["agg"]
        pkg_code = onehot(app_category(s["pkg"]), 6) + str_hash8(s["pkg"])
        # 帧率反馈特征 (v3.1): 流畅度 = 1 - clamp(fvar/25,0,1)
        smooth_feat = 0.0
        if s["fn"] >= 10 and s["fzero"] <= 0.3 and s["favg"] > 0:
            if s["favg"] <= FPS_CAP_MS * 1.05:
                smooth_feat = 1.0
            else:
                smooth_feat = max(0.0, 1.0 - s["fvar"] / 25.0)
        sf = [agg[0]/100, agg[1]/100, agg[2]/100, agg[3]/100, agg[4], agg[5],
              agg[6]/100, agg[7]/4096, agg[8]/24, min(agg[9],300)/300, smooth_feat]
        # 帧率标签 (场景级 -> 每线程)
        label_base = 0.0; skip = True
        if s["fn"] >= 10 and s["fzero"] <= 0.3 and s["favg"] > 0:
            skip = False
            if s["favg"] <= FPS_CAP_MS * 1.05:
                label_base = 0.0
            else:
                smooth = smooth_feat
                if smooth >= 0.8:
                    label_base = 0.0
                elif smooth < 0.5:
                    label_base = 0.8
                else:
                    label_base = 0.4
        th_feats, th_labels, mask = [], [], []
        for (nm, cpu) in s["threads"]:
            tf = [min(cpu,100)/100] + onehot(thread_type_of(nm), 12) + str_hash8(nm)
            th_feats.append(sf + pkg_code + tf)
            if skip:
                th_labels.append([0.0]); mask.append(0)
            else:
                l = label_base * min(1.0, cpu/70.0) if label_base > 0 else 0.0
                th_labels.append([l]); mask.append(1)
        # 补足 6 线程
        while len(th_feats) < 6:
            th_feats.append(sf + pkg_code + [0.0] + onehot(11, 12) + str_hash8("none"))
            th_labels.append([0.0]); mask.append(0)
        Xs.append(sf + pkg_code)
        Xt.append(th_feats[:6]); Yt.append(th_labels[:6]); M.append(mask[:6])
    return Xs, Xt, Yt, M

# ============ 纯 Python 矩阵工具 ============
def matmul(A, B):
    """A(m,k) @ B(k,n) -> (m,n), 用转置加速列访问"""
    Bt = list(zip(*B))
    return [[sum(x*y for x, y in zip(row, col)) for col in Bt] for row in A]

def matmul_At(A, B):
    """A.T(k,m) @ B(m,n) -> (k,n); 稀疏 B 时跳过 0 加速"""
    n_in = len(A[0]); n_out = len(B[0])
    res = [[0.0]*n_out for _ in range(n_in)]
    for r in range(len(A)):
        ar = A[r]; br = B[r]
        for j in range(n_out):
            bj = br[j]
            if bj == 0.0:
                continue
            for i in range(n_in):
                res[i][j] += ar[i]*bj
    return res

def ew_mul(A, B):
    """逐元素乘 (形状相同)"""
    return [[a*b for a, b in zip(ra, rb)] for ra, rb in zip(A, B)]

def relu_mask(X):
    """ReLU: v>0 保留, 否则 0 (同时作为梯度掩码)"""
    return [[v if v > 0.0 else 0.0 for v in row] for row in X]

def sig(v):
    return 1.0/(1.0+math.exp(-v))

def col_sum(A):
    """按列求和 -> (n,)"""
    n = len(A[0])
    s = [0.0]*n
    for row in A:
        for i in range(n):
            s[i] += row[i]
    return s

def bce_list(a, y):
    """a/y 为标量列表 (已验证样本), 返回平均二元交叉熵"""
    eps = 1e-8
    tot = 0.0
    for ai, yi in zip(a, y):
        tot += -(yi*math.log(ai+eps) + (1-yi)*math.log(1-ai+eps))
    return tot / max(1, len(a))

# ============ 双模块模型 ============
class Enc:
    def __init__(self, seed=42):
        r = random.Random(seed)
        s25 = math.sqrt(2.0/25.0); s10 = math.sqrt(2.0/10.0)
        self.W1 = [[r.gauss(0, 1)*s25 for _ in range(10)] for _ in range(25)]
        self.b1 = [0.0]*10
        self.Wk = [[r.gauss(0, 1)*s10 for _ in range(2)] for _ in range(10)]
        self.bk = [0.0]*2
        self.Ws = [[r.gauss(0, 1)*s10 for _ in range(10)] for _ in range(10)]
        self.bs = [0.0]*10
    def fwd(self, X):
        W1t = list(zip(*self.W1)); Wkt = list(zip(*self.Wk)); Wst = list(zip(*self.Ws))
        h = []
        for row in X:
            hr = [max(0.0, sum(x*w for x, w in zip(row, col)) + b)
                  for col, b in zip(W1t, self.b1)]
            h.append(hr)
        kc = [[sig(sum(a*w for a, w in zip(hr, col)) + b) for col, b in zip(Wkt, self.bk)]
              for hr in h]
        s = [[sum(a*w for a, w in zip(hr, col)) + b for col, b in zip(Wst, self.bs)]
             for hr in h]
        return kc, s, h

class Scr:
    def __init__(self, seed=7):
        r = random.Random(seed)
        s31 = math.sqrt(2.0/31.0); s8 = math.sqrt(2.0/8.0)
        self.W1 = [[r.gauss(0, 1)*s31 for _ in range(8)] for _ in range(31)]
        self.b1 = [0.0]*8
        self.W2 = [[r.gauss(0, 1)*s8 for _ in range(1)] for _ in range(8)]
        self.b2 = [0.0]
    def fwd(self, st, xt):
        """st(n,10), xt(n,21) -> 拼接(31) -> relu -> sigmoid"""
        W1t = list(zip(*self.W1))
        h = []
        out = []
        for i in range(len(st)):
            row = st[i] + xt[i]
            hr = [max(0.0, sum(x*w for x, w in zip(row, col)) + b)
                  for col, b in zip(W1t, self.b1)]
            h.append(hr)
            out.append([sig(sum(a*w for a, w in zip(hr, col)) + b)
                        for col, b in zip(zip(*self.W2), self.b2)])
        return out, h

# ============ 导出 (awk 可读, 与 numpy 版布局一致) ============
def export_awk(enc, scr):
    with open(ENC_OUT, "w") as f:
        for i in range(25):   # W1: 25 行
            f.write(" ".join(f"{enc.W1[i][j]:.6f}" for j in range(10)) + "\n")
        f.write(" ".join(f"{v:.6f}" for v in enc.b1) + "\n")
        for i in range(10):
            f.write(" ".join(f"{enc.Wk[i][j]:.6f}" for j in range(2)) + "\n")
        f.write(" ".join(f"{v:.6f}" for v in enc.bk) + "\n")
        for i in range(10):
            f.write(" ".join(f"{enc.Ws[i][j]:.6f}" for j in range(10)) + "\n")
        f.write(" ".join(f"{v:.6f}" for v in enc.bs) + "\n")
    with open(SCR_OUT, "w") as f:
        for i in range(31):
            f.write(" ".join(f"{scr.W1[i][j]:.6f}" for j in range(8)) + "\n")
        f.write(" ".join(f"{v:.6f}" for v in scr.b1) + "\n")
        for i in range(8):
            f.write(" ".join(f"{scr.W2[i][j]:.6f}" for j in range(1)) + "\n")
        f.write(" ".join(f"{v:.6f}" for v in scr.b2) + "\n")
    print(f"[TRAIN-TP] Exported: {ENC_OUT} + {SCR_OUT}")

# ============ 训练 ============
def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    print("=" * 70)
    print("SD730 Neural Scheduler v3.0 - Thread-level Training (PURE PYTHON)")
    print("=" * 70)
    force = "--force" in sys.argv
    if force:
        print("[!] FORCE TRAIN (v3 thread-level, pure-python)")
        print("    ✓ 强制模式: 跳过样本量门槛 (≥300), 用现有 traw 数据直接训练")

    print("\n[1] Loading .traw data...")
    t0 = time.time()
    samples = load_traw()
    if samples is None:
        sys.exit(1)
    print(f"    Samples: {len(samples)} ({time.time()-t0:.1f}s)")
    if len(samples) < 300:
        if force:
            print(f"    ! 警告: 仅 {len(samples)} 条 traw 样本 (<300), 强制模式照常训练; 样本过少模型易过拟合/质量差")
        else:
            print(f"    ! Skip: {len(samples)} < 300")
            sys.exit(0)

    print("\n[2] Building dataset (frame-time labels)...")
    t0 = time.time()
    Xs, Xt, Yt, M = build_dataset(samples)
    print(f"    Scenes: {len(Xs)}x25, Threads: {len(Xt)}x6x46 ({time.time()-t0:.1f}s)")
    n_valid = sum(1 for s_ in M for m in s_ if m == 1)
    n_total = len(M) * 6
    print(f"    Valid thread labels (frame feedback ok): {n_valid}/{n_total} "
          f"({n_valid/max(1,n_total)*100:.0f}%)")
    # v3.2 fix: 0 条有效帧率反馈 -> 模型无标签可学, 禁止导出 (否则导出的是随机初始化权重,
    # 且验证 loss 恒 0.0000 是"空集"假象, 不是模型学会了)
    if n_valid == 0:
        print("  [FATAL] 0 条有效帧率反馈样本, 模型无可学习标签, 不导出模型!")
        print("          这是采集端问题, 不是训练问题:")
        print("          1) cat $MODDIR/data/collector/.frame_stats   (是否存在/新鲜)")
        print("          2) awk -F'|' '{print $13,$14,$15,$16}' $MODDIR/data/collector/*.traw | sort | uniq -c")
        print("             (若全是 0|0|0|1 -> get_frame_stats 从未成功, 修 collector.sh)")
        print("          3) tail -20 /data/local/tmp/sd730-collector.log (v3.2 起有 [frame] 日志)")
        sys.exit(2)

    # 划分 (按场景), 与 numpy 版同种子同流程
    n_tr = int(len(Xs)*0.85)
    idx = list(range(len(Xs)))
    random.Random(3).shuffle(idx)
    Xs = [Xs[i] for i in idx]; Xt = [Xt[i] for i in idx]
    Yt = [Yt[i] for i in idx]; M = [M[i] for i in idx]

    enc, scr = Enc(), Scr()
    lr = 0.05
    print(f"\n[3] Training dual-module (encoder10 + scorer8, {EPOCHS} epochs, lr={lr})...")
    print("    纯 Python 引擎较 numpy 慢, 训练中请耐心等待; 每 10 epochs 打印 loss")

    Xs_tr = Xs[:n_tr]
    # 展平线程维度 (6n x 46 / 6n x 1)
    Xt_tr = [th for s_ in Xt[:n_tr] for th in s_]
    Yt_tr = [y for s_ in Yt[:n_tr] for y in s_]     # 每个 y 是 [l] -> (6n,1)
    Mt_tr = [[m] for s_ in M[:n_tr] for m in s_]    # M 元素是 int -> (6n,1)
    xt_tr = [row[25:46] for row in Xt_tr]          # (6n,21) 线程特征
    n_6 = len(Xt_tr)                                # 6 * n_tr
    mt_sum_raw = sum(row[0] for row in Mt_tr)
    if mt_sum_raw == 0:
        print("  [FATAL] 训练集 0 条有效帧率反馈样本 (有效样本全在验证集), 不导出模型!")
        sys.exit(2)
    mt_sum = max(1, mt_sum_raw)
    W1_first10_T = list(zip(*scr.W1[:10]))          # (8,10)

    t0 = time.time()
    for e in range(EPOCHS):
        # ---- 前向 ----
        kc, s, h_sc = enc.fwd(Xs_tr)                # (n,2) (n,10) (n,10)
        st_tr = [row for row in s for _ in range(6)]  # (6n,10)
        pt, h = scr.fwd(st_tr, xt_tr)               # (6n,1) (6n,8)

        # ---- 线程打分器梯度 (仅有效帧率样本) ----
        # dz = (pt - Yt) * Mt / max(1, Mt.sum())
        dz = [[(pt[i][0] - Yt_tr[i][0]) * Mt_tr[i][0] / mt_sum] for i in range(n_6)]
        # scr.W2 -= lr * (h.T @ dz)   (8,1)
        dW2 = [sum(h[i][j]*dz[i][0] for i in range(n_6)) for j in range(8)]
        for j in range(8):
            scr.W2[j][0] -= lr * dW2[j]
        scr.b2[0] -= lr * sum(dz[i][0] for i in range(n_6))
        # dh = dz @ scr.W2.T * (h > 0)  (6n,8)
        W2t = [scr.W2[j][0] for j in range(8)]      # (8,)
        dh = [[dz[i][0]*W2t[j] if h[i][j] > 0.0 else 0.0 for j in range(8)]
              for i in range(n_6)]
        # scr.W1 -= lr * (xin.T @ dh)  (31,8);  xin = concat(st, xt) (6n,31)
        # 等价于: st.T@dh (10x8) + xt.T@dh (21x8) 分块计算, 避免拼 31 列
        dW1_st = matmul_At(st_tr, dh)               # (10,8)
        dW1_xt = matmul_At(xt_tr, dh)               # (21,8)
        dW1 = dW1_st + dW1_xt                       # (31,8) 逐元素加
        for i in range(31):
            for j in range(8):
                scr.W1[i][j] -= lr * dW1[i][j]
        db1 = col_sum(dh)                           # (8,)
        for j in range(8):
            scr.b1[j] -= lr * db1[j]

        # ---- 场景编码器梯度 ----
        # ds = (dh @ W1[:10].T).reshape(n,6,10).sum(axis=1)  (n,10)
        dhW1 = matmul(dh, W1_first10_T)             # (6n,10)
        ds = []
        for i in range(n_tr):
            row = [0.0]*10
            for j in range(6):
                base = i*6 + j
                for k in range(10):
                    row[k] += dhW1[base][k]
            ds.append(row)
        # enc.Ws -= lr * (h_sc.T @ ds)  (10,10)
        dWs = matmul_At(h_sc, ds)
        for i in range(10):
            for j in range(10):
                enc.Ws[i][j] -= lr * dWs[i][j]
        dbs = col_sum(ds)
        for j in range(10):
            enc.bs[j] -= lr * dbs[j]
        # dhs = ds @ enc.Ws.T * (h_sc > 0)  (n,10)
        WsT = list(zip(*enc.Ws))                    # (10,10) 列
        dhs = [[sum(ds[i][k]*WsT[k][j] for k in range(10)) if h_sc[i][j] > 0.0 else 0.0
                for j in range(10)] for i in range(n_tr)]
        # enc.W1 -= lr * (Xs_tr.T @ dhs)  (25,10)
        dW1e = matmul_At(Xs_tr, dhs)
        for i in range(25):
            for j in range(10):
                enc.W1[i][j] -= lr * dW1e[i][j]
        db1e = col_sum(dhs)
        for j in range(10):
            enc.b1[j] -= lr * db1e[j]

        # ---- k/cap 保持中性 (v3 线程任务为主) ----
        # dz_kc = (kc - 0.5) / n_tr * 0.1
        dz_kc = [[(kc[i][j] - 0.5)/n_tr*0.1 for j in range(2)] for i in range(n_tr)]
        dWk = matmul_At(h_sc, dz_kc)                # (10,2)
        for i in range(10):
            for j in range(2):
                enc.Wk[i][j] -= lr * dWk[i][j]
        dbk = col_sum(dz_kc)
        for j in range(2):
            enc.bk[j] -= lr * dbk[j]
        # dhs_kc = dz_kc @ enc.Wk.T * (h_sc > 0)  (n,10)
        WkT = list(zip(*enc.Wk))                    # (2,10)
        dhs_kc = [[sum(dz_kc[i][k]*WkT[k][j] for k in range(2)) if h_sc[i][j] > 0.0 else 0.0
                   for j in range(10)] for i in range(n_tr)]
        dW1e2 = matmul_At(Xs_tr, dhs_kc)
        for i in range(25):
            for j in range(10):
                enc.W1[i][j] -= lr * dW1e2[i][j]
        db1e2 = col_sum(dhs_kc)
        for j in range(10):
            enc.b1[j] -= lr * db1e2[j]

        # ---- 验证 (测试集) ----
        if e % 10 == 0 or e == EPOCHS - 1:
            Xs_te = Xs[n_tr:]
            kcv, sv, _ = enc.fwd(Xs_te)
            sv_r = [row for row in sv for _ in range(6)]
            Xt_te = [th for s_ in Xt[n_tr:] for th in s_]
            xt_te = [row[25:46] for row in Xt_te]
            pv, _ = scr.fwd(sv_r, xt_te)
            Yt_te = [y for s_ in Yt[n_tr:] for y in s_]
            Mt_te = [m for s_ in M[n_tr:] for m in s_]
            a = [pv[i][0] for i in range(len(pv)) if Mt_te[i] == 1]
            b = [Yt_te[i][0] for i in range(len(Yt_te)) if Mt_te[i] == 1]
            if a:
                loss = bce_list(a, b)
                print(f"  Epoch {e:3d}: thread-val-loss={loss:.4f} ({time.time()-t0:.0f}s)")
            else:
                # v3.2 fix: 空验证集显示 0.0000 极具误导性
                print(f"  Epoch {e:3d}: thread-val-loss=  (no valid val samples) ({time.time()-t0:.0f}s)")

    print("\n[4] Exporting awk models...")
    export_awk(enc, scr)
    print("=" * 70)
    print("✓ v3 model trained (thread-level, frame-time feedback, pure-python)")
    print("=" * 70)

if __name__ == "__main__":
    main()
