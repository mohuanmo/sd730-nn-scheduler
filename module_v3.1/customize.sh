#!/system/bin/sh
# SD730 Smart Scheduler - Installation Script

ui_print "========================================"
ui_print "  SD730 Smart Scheduler"
ui_print "  Probabilistic Learning CPU/GPU Scheduler"
ui_print "  For Snapdragon 730 / 730G"
ui_print "========================================"
ui_print ""

SOC=$(getprop ro.hardware | tr '[:upper:]' '[:lower:]')
CHIPSET=$(getprop ro.board.platform | tr '[:upper:]' '[:lower:]')
DEVICE=$(getprop ro.product.device)

ui_print "[*] Device: $DEVICE"
ui_print "[*] SoC Platform: $CHIPSET"

# NOTE: "trinket" (SM6125 / Snapdragon 665) is intentionally NOT matched here:
# it has a 4+4 topology, while this module assumes the SD730's 2+6 layout.
if echo "$CHIPSET" | grep -qE "(sm6150|sdm730)"; then
    ui_print "[+] Snapdragon 730/730G detected!"
elif echo "$SOC" | grep -qE "(sm6150|sdm730)"; then
    ui_print "[+] Snapdragon 730/730G detected via hardware!"
else
    ui_print "[!] Warning: Snapdragon 730/730G not detected."
    ui_print "[!] Module may not work correctly on this device."
fi

ui_print ""
ui_print "[*] Installing SD730 Smart Scheduler..."

mkdir -p "$MODPATH/config"
mkdir -p "$MODPATH/common"
mkdir -p "$MODPATH/system/bin"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/system/bin/sd730-scheduler" 0 0 0755
set_perm "$MODPATH/common/functions.sh" 0 0 0755

if [ ! -f "$MODPATH/config/learning.db" ]; then
    touch "$MODPATH/config/learning.db"
    chmod 0644 "$MODPATH/config/learning.db"
fi

if [ ! -f "$MODPATH/config/current_mode" ]; then
    echo "balanced" > "$MODPATH/config/current_mode"
    chmod 0644 "$MODPATH/config/current_mode"
fi

if [ ! -f "$MODPATH/config/scene_mode" ]; then
    echo "auto" > "$MODPATH/config/scene_mode"
    chmod 0666 "$MODPATH/config/scene_mode"
fi

if [ ! -f "$MODPATH/config/prediction.conf" ]; then
    cat > "$MODPATH/config/prediction.conf" <<'EOF'
prediction_enabled=true
confidence_threshold=60
max_predictions_per_hour=30
max_false_positive_rate=40
fp_min_predictions=8
fp_lockout_minutes=30
temp_limit=55
battery_limit=30
cooldown_seconds=5
prediction_boost_little_min=1000000
prediction_boost_duration=3
prediction_validation_seconds=180
thermal_zone_pattern=cpu|soc|apss
time_bucket_hours=2
time_weight=2
second_order_enabled=true
second_order_min_total=2
EOF
    chmod 0644 "$MODPATH/config/prediction.conf"
fi

if [ ! -f "$MODPATH/config/prediction2.db" ]; then
    touch "$MODPATH/config/prediction2.db"
    chmod 0644 "$MODPATH/config/prediction2.db"
fi

if [ ! -f "$MODPATH/config/prediction_time.db" ]; then
    touch "$MODPATH/config/prediction_time.db"
    chmod 0644 "$MODPATH/config/prediction_time.db"
fi

if [ ! -f "$MODPATH/config/prediction.db" ]; then
    touch "$MODPATH/config/prediction.db"
    chmod 0644 "$MODPATH/config/prediction.db"
fi

if [ ! -f "$MODPATH/config/prediction_state.conf" ]; then
    touch "$MODPATH/config/prediction_state.conf"
    chmod 0644 "$MODPATH/config/prediction_state.conf"
fi

if [ ! -f "$MODPATH/config/mode_learning.db" ]; then
    touch "$MODPATH/config/mode_learning.db"
    chmod 0644 "$MODPATH/config/mode_learning.db"
fi

if [ ! -f "$MODPATH/config/mode_learning.conf" ]; then
    cat > "$MODPATH/config/mode_learning.conf" <<'EOF'
mode_learning_enabled=true
auto_apply=true
min_samples_normal=5
min_share_normal=60
min_samples_extreme=8
min_share_extreme=80
profile_min_samples=5
ultra_profile_min=60
powersave_profile_max=50
scene_votes_enabled=true
scene_vote_settle_seconds=8
scene_vote_cooldown_minutes=60
scene_vote_exclude=com.omarea.vtools
learned_overrides_scene=true
EOF
    chmod 0644 "$MODPATH/config/mode_learning.conf"
fi

if [ ! -f "$MODPATH/config/thread_pin.conf" ]; then
    cat > "$MODPATH/config/thread_pin.conf" <<'EOF'
# SD730 Smart Scheduler - Thread Pin Engine Configuration
#
# Per-thread hot pinning for the 2+6 topology (big = cpu6-7 = 0xC0).
# Normally at most base_pinned_threads hot threads are locked to the big
# cluster; the budget elastically expands to max_pinned_threads while a THIRD
# thread stays heavy AND the top two saturate both A76 cores.
# Read live every scheduler cycle (~3s). No reboot needed.

thread_pin_enabled=true

# Modes in which per-thread pinning is active (space-separated).
pin_modes=balanced performance ultra

# Hot/cold classification, in % of ONE core (per-tid jiffies delta).
hot_threshold=25
release_threshold=15

# Hysteresis: consecutive cycles above hot_threshold before pinning,
# consecutive cycles below release_threshold before unpinning.
hot_streak=2
release_streak=3

# Elastic big-core budget: normal pin slots / expanded pin slots.
base_pinned_threads=2
max_pinned_threads=3

# Expansion triggers (ALL must hold for escalate_streak consecutive cycles):
#   3rd-hottest thread >= escalate_threshold (percent of one core)
#   top1+top2 loads   >= escalate_pair_load  (both A76 cores genuinely busy)
#   temperature       <  escalate_temp_max   (thermal headroom required)
escalate_threshold=40
escalate_pair_load=120
escalate_streak=2
escalate_temp_max=72

# Hard thermal release: drop ALL pins at/above this temperature. Pinning only
# relocates existing hot load (it creates none), so this sits just above the
# module's ultra->performance thermal guard (75C).
release_temp=78

# Mask for pinned threads (hex, no 0x). c0 = cpu6-7.
big_mask=c0

# Pin the scheduler daemon itself to these cores (hex, no 0x) so the module's
# own overhead (dumpsys, /proc sampling, learning) never touches big cores.
self_pin_enabled=true
self_mask=3f

# Manual instant-pin list (comma-separated thread names, exact match),
# e.g. pin_names=UnityMain,UnityGfxDeviceW,RenderThread
pin_names=

# Threads whose name CONTAINS any of these (|-separated) are never pinned
# and never recorded by the name learner.
name_blacklist=Jit|GC|Finalizer|HeapTaskDaemon|JDWP|Signal Catcher|ReferenceQueue

# Thread-name learning: remember which thread names stay hot per app and
# pre-pin them by name at the next launch (no sampling wait).
tlearn_enabled=true
tlearn_min_samples=5
tlearn_min_share=60
tlearn_min_cpu=10

# Thread correlation prediction: learn "when thread A runs hot, thread B
# follows within tcorr_window_seconds". While A stays hot, B's live threads
# get an advance nice boost (and, if tcorr_pin_candidate=true, become big-core
# pin candidates without waiting for the hot streak). When A cools for
# tcorr_release_streak cycles the boost is reverted (both directions exist:
# boost on predicted heat-up, restore on predicted cool-down).
tcorr_enabled=true
tcorr_window_seconds=12
tcorr_min_samples=8
tcorr_min_share=60
tcorr_release_streak=2

# Nice delta applied to predicted threads (negative = higher priority,
# clamped to [-10,10]; absolute nice is clamped to [-20,19]). 0 disables the
# nice boost and keeps only the pin-candidate fast path.
tcorr_nice_boost=-3

# Let correlation-predicted threads skip the hot_streak wait and compete for
# big-core pin slots immediately (still subject to the elastic budget).
tcorr_pin_candidate=true

# Slot displacement: a genuinely-hot candidate (>= hot_threshold) evicts the
# coolest pinned keeper when it is this many CPU points hotter, or when the
# keeper is currently below release_threshold. 0 disables displacement.
displace_margin=15

# Whole-app mask learning gate. Below mask_min_samples the coarse ceiling is
# the full LITTLE cluster (0x3f) in every mode; the cold splitter narrows it
# per-thread. (fallback_light_load retired in v1.5.3 - still parsed, no effect.)
mask_min_samples=6
fallback_light_load=25

# Cold-thread mask splitter (v1.5.3): an UNPINNED thread's mask is narrowed
# by its own live CPU% (% of one core): >=cold_full_mask_cpu keeps the full
# coarse mask (big-core bits incl. - the only unpinned path to cpu6-7),
# >=cold_wide_mask_cpu gets the little-cluster portion (0x3f),
# >=cold_mid_mask_cpu gets cpu0-3 (0x0f), below it idles on cpu0-1 (0x03).
cold_full_mask_cpu=20
cold_wide_mask_cpu=8
cold_mid_mask_cpu=3

# Self-management detection: observe unknown apps, monitor excellent ones
# hands-off, take over immediately when a heavy thread strands off big cores.
selfmanage_enabled=true
selfmanage_streak=5
selfmanage_intervene_cpu=45
selfmanage_intervene_streak=2
selfmanage_observe_max=8
EOF
    chmod 0644 "$MODPATH/config/thread_pin.conf"
fi

if [ ! -f "$MODPATH/config/selfmanage.db" ]; then
    touch "$MODPATH/config/selfmanage.db"
    chmod 0644 "$MODPATH/config/selfmanage.db"
fi

if [ ! -f "$MODPATH/config/thread_learning.db" ]; then
    touch "$MODPATH/config/thread_learning.db"
    chmod 0644 "$MODPATH/config/thread_learning.db"
fi

if [ ! -f "$MODPATH/config/thread_corr.db" ]; then
    touch "$MODPATH/config/thread_corr.db"
    chmod 0644 "$MODPATH/config/thread_corr.db"
fi

if [ ! -f "$MODPATH/config/gpu_sched.conf" ]; then
    cat > "$MODPATH/config/gpu_sched.conf" <<'EOF'
# SD730 Smart Scheduler - GPU Adaptive Scheduler Configuration (v1.5.4)
# Read live by the watchdog (~1s) and the scheduler loop (~3s). No reboot.
# gpu_sched_enabled=false restores the v1.5.3 verify-only watchdog behavior.
gpu_sched_enabled=true
# Ultra write-first interval in seconds (fractions like 0.5 allowed): the
# whole GPU lock stack is rewritten every interval even when nothing drifted.
lock_write_interval=1
# Ultra relax floor (Hz): the GPU may breathe inside [floor, table max] but
# NEVER below the floor; the ceiling itself never moves. 565MHz default.
ultra_floor_hz=565000000
# Important scene = a foreground thread >= this % of one core (Thread Pin
# Engine sampling). One hot thread re-locks instantly on the next cycle.
important_thread_cpu=25
# Consecutive quiet watchdog cycles required before the floor may drop.
relax_after_cycles=5
# Per-app GPU tiers (non-ultra): min learning samples before the tier of an
# app is trusted; below it the app follows the plain mode range.
profile_min_samples=5
# Tier thresholds on the learned GPU affinity (gpu%): heavy/mid/light.
heavy_gpu_pct=70
mid_gpu_pct=40
# Per-tier bands (Hz), intersected with the active mode's range (the mode
# always wins). *_max_hz=0 = no tier limit (mode/table ceiling applies).
heavy_min_hz=430000000
heavy_max_hz=0
mid_min_hz=267000000
mid_max_hz=650000000
light_min_hz=0
light_max_hz=565000000
EOF
    chmod 0644 "$MODPATH/config/gpu_sched.conf"
fi

ui_print ""
ui_print "[+] Installation complete!"
ui_print ""
ui_print "[*] Features:"
ui_print "    - Probabilistic learning scheduler"
ui_print "    - 4 modes: Powersave / Balanced / Performance / Ultra"
ui_print "    - Scene integration via /data/powercfg.sh (auto-detected)"
ui_print "    - Per-app CPU affinity optimization"
ui_print "    - Per-thread hot pinning (elastic 2->3 big-core budget)"
ui_print "    - App prediction: 2nd-order context + time-of-day aware"
ui_print "    - Thread correlation prediction (advance boost/demote)"
ui_print "    - GPU: write-first ultra lock, adaptive 565MHz floor, per-app tiers"
ui_print ""
ui_print "[*] Usage:"
ui_print "    sd730-scheduler --mode <powersave|balanced|performance|ultra>"
ui_print "    sd730-scheduler --status"
ui_print "    sd730-scheduler --reset-learning"
ui_print ""

# ============================================================
# NN v3.1: Neural Scheduler components (added by v3.1 merge)
# ============================================================
ui_print ""
ui_print "=============================================="
ui_print "  Neural Scheduler v3.1"
ui_print "  - k/cap scene model (TinyMLP 210 params)"
ui_print "  - thread-level dual-module model (737 params)"
ui_print "  - frame-time feedback (jank-aware binding)"
ui_print "  - dual-engine training (numpy / pure-python)"
ui_print "=============================================="
ui_print ""

# 组件权限
set_perm_recursive "$MODPATH/bin" 0 0 0755 0644
# v3.1 merge fix: 启动相关脚本显式 0755 (尽管均以 sh 调用, 防手动 ./ 执行失败)
set_perm "$MODPATH/bin/ensure_collector.sh" 0 0 0755
set_perm "$MODPATH/bin/collector.sh" 0 0 0755
set_perm "$MODPATH/bin/nn_infer.sh" 0 0 0755
set_perm "$MODPATH/bin/nn_infer_v3.sh" 0 0 0755
set_perm "$MODPATH/bin/v3_decision.sh" 0 0 0755
set_perm "$MODPATH/bin/train.sh" 0 0 0755
set_perm "$MODPATH/patch_nn.sh" 0 0 0755
set_perm "$MODPATH/train.py" 0 0 0755
set_perm "$MODPATH/train_pure.py" 0 0 0755
set_perm "$MODPATH/train_thread.py" 0 0 0755
set_perm "$MODPATH/train_thread_pure.py" 0 0 0755

# 数据/模型目录
mkdir -p "$MODPATH/data/collector"
mkdir -p "$MODPATH/model"
set_perm_recursive "$MODPATH/data" 0 0 0755 0644
set_perm_recursive "$MODPATH/model" 0 0 0755 0644

# 默认配置落盘 (nn.conf / v3.conf 若缺失)
# v3.1 merge fix: 原实现是 cp 自身到自身 (无效操作), 缺失时不会真正生成;
# 改为写入完整默认模板。
if [ ! -f "$MODPATH/config/nn.conf" ]; then
    cat > "$MODPATH/config/nn.conf" <<'EOF'
# SD730 Neural Scheduler Configuration v2.1
nn_enabled=true
nn_alpha=0.0
nn_temp_limit=70
nn_model_path=/data/adb/modules/sd730-scheduler/model/mlp_weights.txt
nn_infer_path=/data/adb/modules/sd730-scheduler/bin/nn_infer.sh
nn_data_keep_days=5
nn_train_start_hour=1
nn_train_end_hour=4
nn_user_habit_path=/data/adb/modules/sd730-scheduler/config/nn_habit.db
nn_deep_standby_minutes=30
nn_min_train_samples=500
nn_train_max_temp=55
nn_warmup_seconds=3
nn_warmup_k_boost=0.3
cap_ratio_min=0.5
cap_ratio_max=1.5
EOF
fi
chmod 0644 "$MODPATH/config/nn.conf" 2>/dev/null
if [ ! -f "$MODPATH/config/v3.conf" ]; then
    cat > "$MODPATH/config/v3.conf" <<'EOF'
# SD730 Neural Scheduler v3.2 - Neural Network (thread-level) config
# 神经网络(线程级)模型: 开启后热线程候选按"模型分数"重排 (模型缺失时自动回退规则调度)
# 默认开启 (v3.2): 装好模块即可用, 模型训练后自动生效。
v3_enabled=true

# 自动训练开关: true=训练窗口内自动训练神经网络模型 (默认开启)
# 引擎自动选择: 有 numpy 用 train_thread.py(快), 无 numpy 用 train_thread_pure.py(纯Python)
v3_auto_train=true
EOF
fi
chmod 0644 "$MODPATH/config/v3.conf" 2>/dev/null
ui_print "[+] Neural Scheduler v3.2 installed."
ui_print "[+] 默认: 神经网络模型已启用 (v3_enabled=true) + 自动训练开启 (v3_auto_train=true)"
ui_print "[+] V2 场景级模型已移除 (v3.2), 只保留神经网络(线程级)模型"
ui_print ""
ui_print "[!] 说明: 打补丁/推理/调度 无需 Python (awk/shell 实现)"
ui_print "[!] 但 模型训练 需要 Python3:"
ui_print "[!]   - py2droid (推荐): 系统级 python3"
ui_print "[!]   - 或 Termux: pkg install python"
ui_print "[!]   训练命令:"
ui_print "[!]     sd730-scheduler --nn-train      (自动) / --nn-train-now (强制)"
ui_print "[!]     引擎: 有 numpy -> train_thread.py / 无 numpy -> train_thread_pure.py"
