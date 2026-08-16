#!/usr/bin/env python3
"""
SD730 Neural Scheduler v3.0 - Thread-level Training (frame-time feedback)

数据: data/collector/YYYYMMDD.traw
  ts|pkg|聚合10|fn|favg|fvar|fzero|t1name|t1cpu|...|t6name|t6cpu
标签: 帧时间方差驱动 (帧率反馈)
  有效帧<10 或 0帧比例>30%      -> 跳过该样本 (帧率不可靠)
  帧时间 <= 1.05*16.67ms(60fps) -> 跑满, 标签 0 (已最优)
  流畅度 smooth=1-clamp(fvar/25,0,1) >= 0.8 -> 标签 0 (不需绑)
  卡顿 (smooth<0.5)             -> 高负载线程标签高 (该绑)
  中间                           -> 线性过渡

架构: 场景编码器(24->10) + 线程打分器(10+21->8->1), 联合训练
输出: model/mlp_v3_enc.txt + model/mlp_v3_scr.txt (awk 可读)
"""
import os, glob, sys, time, random
from datetime import datetime
import numpy as np

MODDIR = "/data/adb/modules/sd730-scheduler"
DATA_DIR = f"{MODDIR}/data/collector"
ENC_OUT = f"{MODDIR}/model/mlp_v3_enc.txt"
SCR_OUT = f"{MODDIR}/model/mlp_v3_scr.txt"
KEEP_DAYS = 5
MAX_SAMPLES = 12000       # 场景样本上限 (每组 6 线程)
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
        print("[TRAIN-T] No .traw data (collector v3 sampling not running?)")
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
        print("[TRAIN-T] No valid .traw rows")
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
        print(f"[TRAIN-T] Time-weighted sampling: {len(out)} from {sum(sizes)} rows ({n_files} days)")
        return out
    return [s for d in file_data for s in d]

# ============ 特征与标签 ============
def build_dataset(samples):
    """返回 X_scene(n,24), X_thread(n,6,21), Y_thread(n,6,1), mask(n,6) 有效标志"""
    Xs, Xt, Yt, M = [], [], [], []
    for s in samples:
        agg = s["agg"]
        pkg_code = onehot(app_category(s["pkg"]), 6) + str_hash8(s["pkg"])
        # 帧率反馈特征 (v3.1): 流畅度 = 1 - clamp(fvar/25,0,1) 作为场景输入
        # (推理时由 .frame_stats 提供, 让模型能感知"当前是否卡顿")
        smooth_feat = 0.0
        if s["fn"] >= 10 and s["fzero"] <= 0.3 and s["favg"] > 0:
            if s["favg"] <= FPS_CAP_MS * 1.05:
                smooth_feat = 1.0                       # 跑满: 流畅
            else:
                smooth_feat = max(0.0, 1.0 - s["fvar"] / 25.0)
        sf = [agg[0]/100, agg[1]/100, agg[2]/100, agg[3]/100, agg[4], agg[5],
              agg[6]/100, agg[7]/4096, agg[8]/24, min(agg[9],300)/300, smooth_feat]
        # 帧率标签 (场景级 -> 每线程)
        label_base = 0.0; skip = True
        if s["fn"] >= 10 and s["fzero"] <= 0.3 and s["favg"] > 0:
            skip = False
            if s["favg"] <= FPS_CAP_MS * 1.05:
                label_base = 0.0                      # 跑满: 不需绑
            else:
                smooth = smooth_feat
                if smooth >= 0.8:
                    label_base = 0.0                  # 流畅: 不需绑
                elif smooth < 0.5:
                    label_base = 0.8                  # 卡顿: 该绑
                else:
                    label_base = 0.4                  # 中间
        th_feats, th_labels, mask = [], [], []
        for (nm, cpu) in s["threads"]:
            tf = [min(cpu,100)/100] + onehot(thread_type_of(nm), 12) + str_hash8(nm)
            th_feats.append(sf + pkg_code + tf)
            if skip:
                th_labels.append([0.0]); mask.append(0)   # 帧率不可靠: 不参与训练
            else:
                # 卡顿程度 × 线程负载: 卡顿越重/负载越高 -> 越该绑
                l = label_base * min(1.0, cpu/70.0) if label_base > 0 else 0.0
                th_labels.append([l]); mask.append(1)
        # 补足 6 线程
        while len(th_feats) < 6:
            th_feats.append(sf + pkg_code + [0.0] + onehot(11, 12) + str_hash8("none"))
            th_labels.append([0.0]); mask.append(0)
        Xs.append(sf + pkg_code)
        Xt.append(th_feats[:6]); Yt.append(th_labels[:6]); M.append(mask[:6])
    return (np.array(Xs, np.float32), np.array(Xt, np.float32),
            np.array(Yt, np.float32), np.array(M, np.float32))

# ============ 双模块模型 ============
class Enc:
    def __init__(self, seed=42):
        np.random.seed(seed)
        self.W1 = np.random.randn(25,10).astype(np.float32)*np.sqrt(2/25)
        self.b1 = np.zeros(10, np.float32)
        self.Wk = np.random.randn(10,2).astype(np.float32)*np.sqrt(2/10)
        self.bk = np.zeros(2, np.float32)
        self.Ws = np.random.randn(10,10).astype(np.float32)*np.sqrt(2/10)
        self.bs = np.zeros(10, np.float32)
    def fwd(self, X):
        h = np.maximum(X @ self.W1 + self.b1, 0)
        kc = 1/(1+np.exp(-(h @ self.Wk + self.bk)))
        s = h @ self.Ws + self.bs
        return kc, s, h

class Scr:
    def __init__(self, seed=7):
        np.random.seed(seed)
        self.W1 = np.random.randn(31,8).astype(np.float32)*np.sqrt(2/31)
        self.b1 = np.zeros(8, np.float32)
        self.W2 = np.random.randn(8,1).astype(np.float32)*np.sqrt(2/8)
        self.b2 = np.zeros(1, np.float32)
    def fwd(self, st, xt):
        x = np.concatenate([st, xt], axis=1)
        h = np.maximum(x @ self.W1 + self.b1, 0)
        return 1/(1+np.exp(-(h @ self.W2 + self.b2))), h

def bce(a, y):
    eps = 1e-8
    return -np.mean(y*np.log(a+eps) + (1-y)*np.log(1-a+eps))

# ============ 导出 (awk 可读, 与 nn_infer_v3.sh 布局一致) ============
def export_awk(enc, scr):
    with open(ENC_OUT, "w") as f:
        for i in range(25):   # W1: 25 行 (v3.1 加 smooth 特征)
            f.write(" ".join(f"{float(enc.W1[i,j]):.6f}" for j in range(10)) + "\n")
        f.write(" ".join(f"{float(v):.6f}" for v in enc.b1) + "\n")
        for i in range(10):
            f.write(" ".join(f"{float(enc.Wk[i,j]):.6f}" for j in range(2)) + "\n")
        f.write(" ".join(f"{float(v):.6f}" for v in enc.bk) + "\n")
        for i in range(10):
            f.write(" ".join(f"{float(enc.Ws[i,j]):.6f}" for j in range(10)) + "\n")
        f.write(" ".join(f"{float(v):.6f}" for v in enc.bs) + "\n")
    with open(SCR_OUT, "w") as f:
        for i in range(31):
            f.write(" ".join(f"{float(scr.W1[i,j]):.6f}" for j in range(8)) + "\n")
        f.write(" ".join(f"{float(v):.6f}" for v in scr.b1) + "\n")
        for i in range(8):
            f.write(" ".join(f"{float(scr.W2[i,j]):.6f}" for j in range(1)) + "\n")
        f.write(" ".join(f"{float(v):.6f}" for v in scr.b2) + "\n")
    print(f"[TRAIN-T] Exported: {ENC_OUT} + {SCR_OUT}")

# ============ 训练 ============
def main():
    # 实时日志 (v3.1.1): 见 train.py 注释
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)
    print("=" * 70)
    print("SD730 Neural Scheduler v3.0 - Thread-level Training")
    print("=" * 70)
    force = "--force" in sys.argv
    if force:
        print("[!] FORCE TRAIN (v3 thread-level)")
        print("    ✓ 强制模式: 跳过样本量门槛 (≥300), 用现有 traw 数据直接训练")

    print("\n[1] Loading .traw data...")
    samples = load_traw()
    if samples is None:
        sys.exit(1)
    print(f"    Samples: {len(samples)}")
    if len(samples) < 300:
        if force:
            print(f"    ! 警告: 仅 {len(samples)} 条 traw 样本 (<300), 强制模式照常训练; 样本过少模型易过拟合/质量差")
        else:
            print(f"    ! Skip: {len(samples)} < 300")
            sys.exit(0)

    print("\n[2] Building dataset (frame-time labels)...")
    Xs, Xt, Yt, M = build_dataset(samples)
    print(f"    Scenes: {Xs.shape} (25=24+smooth), Threads: {Xt.shape}")
    n_valid = int(M.sum())
    print(f"    Valid thread labels (frame feedback ok): {n_valid}/{M.size} "
          f"({n_valid/M.size*100:.0f}%)")
    # v3.2 fix: 0 条有效帧率反馈 -> 模型无标签可学, 禁止导出
    if n_valid == 0:
        print("  [FATAL] 0 条有效帧率反馈样本, 模型无可学习标签, 不导出模型!")
        print("          这是采集端问题: .frame_stats 未成功写入 / traw 第 13-16 列全为 0|0|0|1")
        print("          排查: tail -20 /data/local/tmp/sd730-collector.log; cat $MODDIR/data/collector/.frame_stats")
        sys.exit(2)

    # 划分 (按场景)
    n_tr = int(len(Xs)*0.85)
    idx = np.random.RandomState(3).permutation(len(Xs))
    Xs, Xt, Yt, M = Xs[idx], Xt[idx], Yt[idx], M[idx]

    enc, scr = Enc(), Scr()
    print("\n[3] Training dual-module (encoder10 + scorer8, 200 epochs)...")
    lr = 0.05
    for e in range(200):
        kc, s, h_sc = enc.fwd(Xs[:n_tr])
        Xt_tr = Xt[:n_tr].reshape(-1, 46); Yt_tr = Yt[:n_tr].reshape(-1, 1)
        Mt_tr = M[:n_tr].reshape(-1, 1)
        if Mt_tr.sum() == 0:
            print("  [FATAL] 训练集 0 条有效帧率反馈样本 (有效样本全在验证集), 不导出模型!")
            sys.exit(2)
        st_tr = np.repeat(s, 6, axis=0)
        pt, h = scr.fwd(st_tr, Xt_tr[:, 25:46])
        # 仅有效帧率样本参与损失
        dz = (pt - Yt_tr) * Mt_tr / max(1, Mt_tr.sum())
        xin = np.concatenate([st_tr, Xt_tr[:, 25:46]], axis=1)
        scr.W2 -= lr*(h.T@dz); scr.b2 -= lr*dz.sum(0)
        dh = dz @ scr.W2.T * (h > 0)
        scr.W1 -= lr*(xin.T@dh); scr.b1 -= lr*dh.sum(0)
        ds = (dh @ scr.W1[:10].T).reshape(n_tr, 6, 10).sum(axis=1)
        enc.Ws -= lr*(h_sc[:n_tr].T@ds); enc.bs -= lr*ds.sum(0)
        dhs = ds @ enc.Ws.T * (h_sc[:n_tr] > 0)
        enc.W1 -= lr*(Xs[:n_tr].T@dhs); enc.b1 -= lr*dhs.sum(0)
        # k/cap 保持中性 (v3 线程任务为主)
        dz_kc = (kc - np.array([0.5, 0.5])) / n_tr * 0.1
        enc.Wk -= lr*(h_sc.T@dz_kc); enc.bk -= lr*dz_kc.sum(0)
        dhs_kc = dz_kc @ enc.Wk.T * (h_sc > 0)
        enc.W1 -= lr*(Xs[:n_tr].T@dhs_kc); enc.b1 -= lr*dhs_kc.sum(0)
        if e % 25 == 0 or e == 199:
            kcv, sv, _ = enc.fwd(Xs[n_tr:])
            sv_r = np.repeat(sv, 6, axis=0)
            Xt_v = Xt[n_tr:].reshape(-1, 46); Yt_v = Yt[n_tr:].reshape(-1, 1)
            Mt_v = M[n_tr:].reshape(-1, 1)
            pv, _ = scr.fwd(sv_r, Xt_v[:, 25:46])
            if Mt_v.sum() > 0:
                loss = bce(pv[Mt_v.flatten()==1], Yt_v[Mt_v.flatten()==1])
                print(f"  Epoch {e:3d}: thread-val-loss={loss:.4f}")
            else:
                print(f"  Epoch {e:3d}: thread-val-loss=  (no valid val samples)")

    print("\n[4] Exporting awk models...")
    export_awk(enc, scr)
    print("=" * 70)
    print("✓ v3 model trained (thread-level, frame-time feedback)")
    print("=" * 70)

if __name__ == "__main__":
    main()
