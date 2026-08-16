# v3.2 / v3.2.2 修复: 训练 loss 恒为 0.0000 / 有效标签 0% 的问题

## 〇、v3.2.2 追加修复（刷 v3.2.2 包的用户看这里）

v3.2 修复上线后（`[frame]` 日志开始输出 = 修复生效），设备实测暴露 3 个后续问题，已在本包修复：

| 现象 | 原因 | v3.2.2 修复 |
|------|------|-------------|
| 失败日志每 5s 刷一条 | 采集循环 5s 一次，失败就记 | `frame_log()` 30s 节流 |
| 视频 app（bilibilihd 播放中）也报"帧数不足" | 候选 layer 取了**第一个** ≥10 帧的，往往是 UI/弹幕层（帧少），不是视频渲染层 | 遍历所有候选，选**有效帧数最多**的 layer |
| 微信等报 "no layer matching" | `dumpsys SurfaceFlinger --list` 在 SF 忙时输出几千行，**5s timeout 被掐断**，后半段 app 层没打出来 | `--list` 超时 5s → **10s** |

本地回归测试（`fix/test_get_frame_stats_v322.sh`，mock dumpsys）全部通过：
- 视频场景正确选中视频渲染层：`59|33.33|0.00|0.53`（30fps）
- 微信低频渲染：`19|16.67|0.00|0.84`（zero 高 → 训练端正确跳过）
- 5 次连续失败只打 1 条日志
- SF 忙时 `--list`：timeout 5s 被掐断（复现旧 bug），timeout 10s 成功（修复生效）

**注意**：`.frame_stats` 出现 `79|50.84|11349.47|0.35` 这类数据是**正常的**——这是设置/微信/桌面等**静止、低频渲染界面**，`--latency` 的 128 个 vsync 槽位大半是空槽（zero_ratio 0.35~0.84 > 0.3）。训练端跳过它们是**正确行为**（静止界面不能当卡顿标标签，否则模型会乱绑核）。
要攒有效训练数据，请用**游戏 / 视频播放**这类持续渲染场景（zero_ratio 应 <0.1），例如打 15-20 分钟游戏再看 `.frame_stats`。

---

# v3.2 修复: 训练 loss 恒为 0.0000 / 有效标签 0% 的问题

## 一、结论

`Valid thread labels (frame feedback ok): 0/2424 (0%)` + `thread-val-loss=0.0000` 是**同一个问题的两种表现**：

1. `.traw` 里 404 条样本的帧率反馈字段全部是**采集失败默认值** `fn=0|favg=0|fvar=0|fzero=1`，
   训练端 `build_dataset()` 的判定 `fn>=10 and fzero<=0.3 and favg>0` 全部不满足 → 全部打 `mask=0`（不参与训练）。
2. 验证集因此是**空集**，`bce_list(a, b) if a else 0.0` 对空集直接返回 `0.0` —— 这个 0 不是"模型学会了"，
   而是"根本没有样本可算"。
3. 梯度也全被 `mask` 掉（`mt_sum = max(1, sum(...))` 实际为 0），60 个 epoch 里打分器权重**一次都没更新**，
   导出的 `mlp_v3_scr.txt` 就是随机初始化（seed=7）的权重，等于**没训**。

## 二、根因在采集端 `collector.sh` 的 `get_frame_stats()`

```sh
layer=$(dumpsys_t SurfaceFlinger --list | grep -i "${pkg%.*}" | head -1)
```

三个问题叠加导致在设备上几乎永远拿不到有效帧数据：

| # | 问题 | 后果 |
|---|------|------|
| 1 | `${pkg%.*}` 只截掉包名**最后一段**（如 `com.tencent.mm`→`com.tencent`，`com.android.browser`→`com.android`） | `com.android.*`/`com.google.*`/`com.tencent.*` 会命中**大量系统层**，`head -1` 抓到的基本不是前台 app 的 layer |
| 2 | `head -1` 只取第一个匹配 | 拿到错误 layer 后 `--latency` 返回空/无新帧 → `n<10` 或全 0 → 判定无效 |
| 3 | `tail -n +4` 硬跳行解析 | 不同 Android 版本的 `--latency` 表头行数不同，解析错位 |
| 4 | 失败完全静默，且 `.frame_stats` 跨 app 复用 | 换 app 后仍用上个 app 的帧统计给新 app 的线程打标签（脏标签）；失败无法排查 |

## 三、修复内容

### 1. `bin/collector.sh`（采集端，核心）
- layer 匹配：完整包名**固定串匹配**（`grep -iF`），优先带 `#` 的真实渲染 layer，**逐候选尝试**直到拿到 ≥10 有效帧；
- 解析：只取 **3 列纯数字行**（自动跳过层名/刷新周期/表头），不再 `tail -n +4`；
- 新增 `.frame_stats_owner`：前台 app 切换即清空旧帧统计；
- 失败写 `/data/local/tmp/sd730-collector.log` 的 `[frame]` 日志，不再静默；
- traw 追加时增加**新鲜度（<30s）＋归属（当前 app）**双校验。

### 2. `train_thread_pure.py` / `train_thread.py`（训练端，防御）
- `n_valid == 0` 时直接 `sys.exit(2)` **拒绝导出模型**（否则会把随机初始化模型当真模型部署）；
- 训练集有效样本为 0 同样拒绝导出；
- 验证集为空时打印 `(no valid val samples)` 而不是误导性的 `0.0000`。

## 四、设备端确认（先跑这些，确认病因）

```sh
# 1) traw 第 13-16 列分布: 如果全是 "0|0|0|1" 就是采集失败默认值
awk -F'|' '{print $13,$14,$15,$16}' /data/adb/modules/sd730-scheduler/data/collector/*.traw | sort | uniq -c

# 2) 当前帧统计文件: 不存在/太旧 = get_frame_stats 没成功过
ls -l /data/adb/modules/sd730-scheduler/data/collector/.frame_stats
cat  /data/adb/modules/sd730-scheduler/data/collector/.frame_stats

# 3) 采集日志 (修复后会有 [frame] 失败原因)
tail -30 /data/local/tmp/sd730-collector.log

# 4) 手动验证 layer 能否匹配 (游戏在前台时执行)
dumpsys SurfaceFlinger --list | grep -i "com.tencent.tmgp"
dumpsys SurfaceFlinger --latency "com.tencent.tmgp.sgame/com.tencent.tmgp.sgame.unity3d.UnityPlayerActivity#0" | head -5
```

## 五、部署步骤

```sh
# 1) 覆盖采集脚本 (推荐直接用 fix/collector.sh.v3.2-fix.sh)
adb push fix/collector.sh.v3.2-fix.sh /data/adb/modules/sd730-scheduler/bin/collector.sh
adb shell "chmod 755 /data/adb/modules/sd730-scheduler/bin/collector.sh"

# 2) 重启采集器 (杀掉旧进程, 由 ensure_collector/watchdog 拉起, 或手动)
adb shell "pkill -f 'bin/collector.sh'; sleep 1; sh /data/adb/modules/sd730-scheduler/bin/collector.sh &"

# 3) 覆盖训练脚本 (防御性修复)
adb push train_thread.py train_thread_pure.py /data/adb/modules/sd730-scheduler/

# 4) 正常使用手机 (打游戏/刷视频) 至少几十分钟, 攒有效帧数据
#    检查: cat .../.frame_stats  应出现 n>=10 且 avg>0 的值

# 5) 重新训练
sd730-scheduler --nn-train-now
# 期望看到: Valid thread labels ... 不再是 0%, 且 thread-val-loss 是真实数值且逐 epoch 变化
```

## 六、本地验证结果（已在仓库内跑通）

- 修复后 `get_frame_stats`（mock dumpsys）: 游戏卡顿→`59|27.97|248.97|0.00`（有效），60fps→`59|16.67|0.00|0.00`（跑满，标签 0），静止页→rc=1（正确跳过）；
- 训练端: 合成 300 条 traw（200 卡顿+100 跑满）→ `Valid 600/1800 (33%)`，loss `0.6725 → 0.6669` 真实下降；
- 全默认值 404 条 → 与你的日志完全一致 `0/2424 (0%)`，现在会 `[FATAL]` 退出且不导出模型。
