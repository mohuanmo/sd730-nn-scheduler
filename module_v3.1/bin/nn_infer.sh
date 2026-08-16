#!/system/bin/sh
################################################################################
# NN Inferencer v2.1.1 - TinyMLP Forward Pass in awk
# 
# Output: "k cap_ratio" (space separated)
#   k:        0.5 - 2.0, aggressiveness coefficient
#   cap_ratio: 0.5 - 1.5, elastic budget multiplier
#
# Model format:
#   Line 1: IN_DIM HID_DIM OUT_DIM
#   W1, b1, W2, b2
#
# Fallback: k=1.0 cap_ratio=1.0 (neutral)
#
# 修正 (v2.1.1):
#   1) CPU/threads/mem 从 .coll_state 完整快照读取 (pkg|jiffies|ts|threads|mem|cpu),
#      此前误读第3列(时间戳)当 CPU, 导致特征爆炸。
#   2) 特征顺序与 train.py 的 load_raw 严格一致:
#      [cpu, gpu, temp, batt, charging, screen, threads, mem, hour, fg_duration]
#      归一化除数也与 train.py normalize() 一致:
#      [100, 100, 100, 100, 1, 1, 100, 4096, 24, 300]
#      (删除了错位的 mode/warmup 特征 —— 训练端从未学习过它们)
################################################################################

MODEL="/data/adb/modules/sd730-scheduler/model/mlp_weights.txt"

[ -f "$MODEL" ] || { echo "1.0 1.0"; exit 0; }

# ---- Read system state ----
# v3.1.1: 只统计真正的温度传感器 (-tz/-usr/含therm/battery/bms),
# 过滤 lmh-dcvs/ibat/vbat/bcl/soc/step/lowf; 单位归一化 + [10,90]°C 过滤。
# 旧实现全 zone 取最大/1000 会把 lmh-dcvs 的 75000 误采成 75°C, 污染推理特征。
MAX_TEMP=0
for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$zone" ] || continue
    TYPE=$(cat "${zone%/temp}/type" 2>/dev/null)
    case "$TYPE" in
        *-tz|*-usr|*therm*|battery|bms) ;;
        *) continue ;;
    esac
    T=$(cat "$zone" 2>/dev/null)
    case "$T" in ''|*[!0-9]*) continue ;; esac
    [ "$T" -le 0 ] && continue
    C=0
    if [ "$T" -ge 10000 ] && [ "$T" -le 150000 ]; then
        C=$((T / 1000))                     # 毫摄氏度: 48000 -> 48
    elif [ "$T" -ge 100 ] && [ "$T" -le 1500 ]; then
        C=$(( (T + 5) / 10 ))               # 十分之一度: 480 -> 48
    elif [ "$T" -ge 10 ] && [ "$T" -le 150 ]; then
        C=$T                                # 摄氏度
    fi
    [ "$C" -ge 10 ] && [ "$C" -le 90 ] && [ "$C" -gt "$MAX_TEMP" ] && MAX_TEMP=$C
done
TEMP=$MAX_TEMP
[ "$TEMP" -gt 100 ] && TEMP=100
[ "$TEMP" -lt 0 ] && TEMP=0

GPU=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d '% \r\t')
case "$GPU" in ''|*[!0-9]*) GPU=0 ;; esac
[ "$GPU" -gt 100 ] && GPU=100
[ "$GPU" -lt 0 ] && GPU=0

BATT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "50")
case "$BATT" in ''|*[!0-9]*) BATT=50 ;; esac
[ "$BATT" -gt 100 ] && BATT=100
[ "$BATT" -lt 0 ] && BATT=0

CHARGING=0
BATT_STATUS=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")
case "$BATT_STATUS" in Charging|Charging*) CHARGING=1 ;; esac

SCREEN_ON=1
FG_APP=$(dumpsys activity activities 2>/dev/null | grep -E "mResumedActivity" | head -1 | sed -n 's/.*{[^}]* \([^ ]*\)\/.*/\1/p')
case "$FG_APP" in
    ""|"android"*|"com.android.systemui"*) SCREEN_ON=0 ;;
esac

HOUR=$(date +%H)
HOUR=${HOUR#0}
case "$HOUR" in ''|*[!0-9]*) HOUR=12 ;; esac

# ---- 状态快照读取 (v2.1.1) ----
# collector.sh 写入格式: pkg|jiffies|ts|threads|mem|cpu
COLL_STATE="/data/adb/modules/sd730-scheduler/data/collector/.coll_state"
CPU=0
THREADS=0
MEM=0
if [ -f "$COLL_STATE" ]; then
    CPU=$(cut -d'|' -f6 "$COLL_STATE" 2>/dev/null)
    THREADS=$(cut -d'|' -f4 "$COLL_STATE" 2>/dev/null)
    MEM=$(cut -d'|' -f5 "$COLL_STATE" 2>/dev/null)
    case "$CPU" in ''|*[!0-9]*) CPU=0 ;; esac
    case "$THREADS" in ''|*[!0-9]*) THREADS=0 ;; esac
    case "$MEM" in ''|*[!0-9]*) MEM=0 ;; esac
fi
[ "$CPU" -gt 100 ] && CPU=100
[ "$CPU" -lt 0 ] && CPU=0
[ "$THREADS" -gt 500 ] && THREADS=500

FG_DURATION=0
FG_DUR_FILE="/data/adb/modules/sd730-scheduler/data/collector/.fg_duration"
if [ -f "$FG_DUR_FILE" ]; then
    FG_DURATION=$(cat "$FG_DUR_FILE" 2>/dev/null)
    case "$FG_DURATION" in ''|*[!0-9]*) FG_DURATION=0 ;; esac
fi

# ---- awk MLP forward pass (10 inputs -> 2 outputs) ----
# 特征顺序与 train.py load_raw + normalize 严格一致:
#   x1=cpu/100  x2=gpu/100  x3=temp/100  x4=batt/100  x5=charging
#   x6=screen   x7=threads/100  x8=mem/4096  x9=hour/24  x10=fg_duration/300
awk -v cpu="$CPU" -v gpu="$GPU" -v temp="$TEMP" -v batt="$BATT" \
    -v chg="$CHARGING" -v screen="$SCREEN_ON" \
    -v threads="$THREADS" -v mem="$MEM" -v fgdur="$FG_DURATION" -v hour="$HOUR" \
'BEGIN {
    x[1] = cpu / 100.0
    x[2] = gpu / 100.0
    x[3] = temp / 100.0
    x[4] = batt / 100.0
    x[5] = chg
    x[6] = screen
    x[7] = threads / 100.0
    x[8] = mem / 4096.0
    x[9] = hour / 24.0
    x[10] = (fgdur > 300) ? 1.0 : fgdur / 300.0

    model = "/data/adb/modules/sd730-scheduler/model/mlp_weights.txt"

    if ((getline line < model) <= 0) { print "1.0 1.0"; exit }
    split(line, hdr)
    n_in = hdr[1] + 0
    n_hid = hdr[2] + 0
    n_out = hdr[3] + 0
    if (n_in != 10 || n_hid < 1 || n_out != 2) { print "1.0 1.0"; exit }

    for (i = 1; i <= n_in; i++) {
        if ((getline line < model) <= 0) { print "1.0 1.0"; exit }
        split(line, row)
        for (j = 1; j <= n_hid; j++) W1[i,j] = row[j] + 0
    }
    if ((getline line < model) <= 0) { print "1.0 1.0"; exit }
    split(line, row)
    for (j = 1; j <= n_hid; j++) b1[j] = row[j] + 0

    for (i = 1; i <= n_hid; i++) {
        if ((getline line < model) <= 0) { print "1.0 1.0"; exit }
        split(line, row)
        for (j = 1; j <= n_out; j++) W2[i,j] = row[j] + 0
    }
    if ((getline line < model) <= 0) { print "1.0 1.0"; exit }
    split(line, row)
    for (j = 1; j <= n_out; j++) b2[j] = row[j] + 0

    close(model)

    for (j = 1; j <= n_hid; j++) {
        z = b1[j]
        for (i = 1; i <= n_in; i++) z += x[i] * W1[i,j]
        h[j] = (z > 0) ? z : 0
    }

    # Output 1: k -> sigmoid -> 0.5-2.0
    o1 = b2[1]
    for (i = 1; i <= n_hid; i++) o1 += h[i] * W2[i,1]
    k = 0.5 + 1.5 / (1.0 + exp(-o1))

    # Output 2: cap_ratio -> sigmoid -> 0.5-1.5
    o2 = b2[2]
    for (i = 1; i <= n_hid; i++) o2 += h[i] * W2[i,2]
    cap = 0.5 + 1.0 / (1.0 + exp(-o2))

    printf "%.4f %.4f\n", k, cap
}'
