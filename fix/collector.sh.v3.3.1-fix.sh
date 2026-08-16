#!/system/bin/sh
################################################################################
# Collector v2.1 - Time-series data acquisition
# 
# Output format:
#   ts|pkg|cpu|gpu|temp|battery|charging|screen|threads|mem|mode|fg_duration|hour
################################################################################

MODDIR="/data/adb/modules/sd730-scheduler"
DATA_DIR="$MODDIR/data/collector"
mkdir -p "$DATA_DIR"

# v3.1 merge fix: 采集器自我登记 PID, 供 ensure_collector.sh / watchdog 判活
# (与 ensure_collector.sh 写入的值一致; 双保险防 PID 文件丢失)
echo $$ > /data/local/tmp/sd730-collector.pid 2>/dev/null

COLL_STATE="$DATA_DIR/.coll_state"
FG_DUR_FILE="$DATA_DIR/.fg_duration"
FG_START_FILE="$DATA_DIR/.fg_start"
THREADS_SNAP="$DATA_DIR/.threads_snapshot"   # v3.0: 线程快照 (name|cpu|21维特征)
FRAME_STATS="$DATA_DIR/.frame_stats"         # v3.0: 帧率反馈 (帧数|平均帧时间|方差|0帧比例)
FRAME_STATS_OWNER="$DATA_DIR/.frame_stats_owner"  # v3.2 fix: 该帧统计属于哪个前台 app (防跨 app 复用脏数据)
FRAME_LOG_STAMP="$DATA_DIR/.frame_log_stamp"      # v3.2.2: 帧率失败日志节流时间戳
CORE_LOAD="$DATA_DIR/.core_load"              # v3.3: 每核使用率% (c0|c1|...|c7)
CORE_LOAD_PREV="$DATA_DIR/.core_load_prev"    # v3.3: /proc/stat 差分快照

# v3.2.2: 帧率失败日志节流 (30s 一条). 旧版每 5s 轮询失败打一条, 一天几千条刷屏
frame_log() {
    local now=$(date +%s) last=0
    [ -f "$FRAME_LOG_STAMP" ] && last=$(cat "$FRAME_LOG_STAMP" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -ge 30 ] 2>/dev/null; then
        echo "$now" > "${FRAME_LOG_STAMP}.tmp.$$" 2>/dev/null && mv "${FRAME_LOG_STAMP}.tmp.$$" "$FRAME_LOG_STAMP" 2>/dev/null
        log_msg "$1"
    fi
}
V3_LAST=0                                     # v3.0: 上次线程/帧率采样时间

# 采集数据保留天数 (v2.1.6): 统一从 nn.conf 读取 nn_data_keep_days, 默认 5 天
# 每 1 秒主循环调用 rotate_data() 轮询清除过期 .raw, 防止数据无限增长
KEEP_DAYS=5
if [ -f "$MODDIR/config/nn.conf" ]; then
    KEEP_DAYS=$(grep "^nn_data_keep_days=" "$MODDIR/config/nn.conf" 2>/dev/null | cut -d'=' -f2-)
fi
case "$KEEP_DAYS" in ''|*[!0-9]*) KEEP_DAYS=5 ;; esac
[ "$KEEP_DAYS" -lt 1 ] && KEEP_DAYS=5
[ "$KEEP_DAYS" -gt 30 ] && KEEP_DAYS=30

# 独立轻量日志 (collector.sh 不 source functions.sh, 自带 log_msg)
# v3.1.1: 加滚动限制, 超 256KB 保留末 200 行, 防止无限增长
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> /data/local/tmp/sd730-collector.log 2>/dev/null || true
    local size=$(wc -c < /data/local/tmp/sd730-collector.log 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt 262144 ] 2>/dev/null; then
        tail -n 200 /data/local/tmp/sd730-collector.log > /data/local/tmp/sd730-collector.log.tmp 2>/dev/null && \
            mv /data/local/tmp/sd730-collector.log.tmp /data/local/tmp/sd730-collector.log 2>/dev/null
    fi
}

# v3.1 fix: dumpsys 偶发阻塞 (system_server 忙/ binder 拥塞) 会卡死整个采集循环
# (表现为 .coll_state 停在 3 字段旧格式、.raw 不再增长)。这里统一加 5s 硬超时:
# 有 toybox timeout 就用, 没有就退化为原始调用 (至少大部分 ROM 有 timeout)。
dumpsys_t() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 dumpsys "$@" 2>/dev/null
    else
        dumpsys "$@" 2>/dev/null
    fi
}

# 修正(v2.1.1): 原实现 "echo >> tmp && mv tmp OUTFILE" 每次都会用 tmp 覆盖 OUTFILE,
# 导致 .raw 永远只有最后一行, 训练数据永远攒不够。
# 单写者场景下, 单行 echo >> 是 O_APPEND 原子追加, 读者要么读到完整行要么读不到, 安全。
atomic_append() {
    echo "$1" >> "$OUTFILE" 2>/dev/null
}

rotate_data() {
    local now_ts=$(date +%s)
    for f in "$DATA_DIR"/*.raw; do
        [ -f "$f" ] || continue
        # v3.1 fix: stat 失败时(输出为空/非数字)不删除 —— 否则 fage 会算成
        # 整个 epoch 秒数, 把刚写的新数据当"过期"删掉 (Data files 恒为 0)
        local mtime=""
        mtime=$(stat -c %Y "$f" 2>/dev/null)
        case "$mtime" in ''|*[!0-9]*) continue ;; esac
        local fage=$((now_ts - mtime))
        if [ "$fage" -gt $((KEEP_DAYS * 86400)) ] 2>/dev/null; then
            rm -f "$f"
            log_msg "[collector] rotated out stale data: $(basename "$f") (age ${fage}s > ${KEEP_DAYS}d)"
        fi
    done
}

get_fg_app() {
    local pkg=""
    pkg=$(dumpsys_t activity activities | grep -E "mResumedActivity" | head -1 | sed -n 's/.*{[^}]* \([^ ]*\)\/.*/\1/p')
    [ -z "$pkg" ] && pkg=$(dumpsys_t window displays | grep -E "mFocusedWindow" | head -1 | sed -n 's/.* \([^ ]*\)\/.*/\1/p')
    [ -z "$pkg" ] && pkg=$(dumpsys_t activity activities | grep -E "mFocusedApp" | head -1 | sed -n 's/.*[[:space:]]\([^ ]*\)\/.*/\1/p')
    if [ -z "$pkg" ]; then
        local pdir cs fcmd
        for pdir in /proc/[0-9]*; do
            # v3.1 fix: 内建 read + [ -r ] 守卫, 免 fork 且不刷 mksh 诊断
            cs=""
            [ -r "$pdir/cpuset" ] && { IFS= read -r cs < "$pdir/cpuset"; } 2>/dev/null
            case "$cs" in *top-app*) ;; *) continue ;; esac
            fcmd=""
            [ -r "$pdir/cmdline" ] && { IFS= read -r fcmd < "$pdir/cmdline"; } 2>/dev/null
            case "$fcmd" in *.*) pkg=$fcmd; break ;; esac
        done
    fi
    case "$pkg" in *.*) echo "$pkg" | tr -d '[:space:]' ;; *) echo "" ;; esac
}

# v3.1 fix: 进程列表缓存 (5s TTL) + 内建 read (零 fork)。
# 旧实现每轮 3-6 次全量 /proc 扫描、每次扫描对每个 PID fork 一次 cat,
# 设备上 400+ 进程 = 每轮上千次 fork, 繁忙时一轮循环被拖到数十秒
# (表现为 .raw 几乎不增长 / 状态时间戳冻结)。前台 app 的 pid 集几秒内几乎不变。
PIDS_CACHE_PKG=""
PIDS_CACHE_TS=0
PIDS_CACHE=""

get_pids() {
    local pkg="$1"
    [ -z "$pkg" ] && return
    if [ -n "$ts" ] && [ "$pkg" = "$PIDS_CACHE_PKG" ] && [ $((ts - PIDS_CACHE_TS)) -lt 5 ] 2>/dev/null; then
        echo "$PIDS_CACHE"
        return
    fi
    PIDS_CACHE_PKG="$pkg"
    PIDS_CACHE_TS=$ts
    PIDS_CACHE=""
    local pid_dir cmd
    for pid_dir in /proc/[0-9]*; do
        cmd=""
        # [ -r ] 守卫 + 组重定向: 进程刚消失时也不触发 mksh "can't open" 刷日志
        [ -r "$pid_dir/cmdline" ] && { IFS= read -r cmd < "$pid_dir/cmdline"; } 2>/dev/null
        case "$cmd" in "$pkg"|"$pkg":*) PIDS_CACHE="${PIDS_CACHE} ${pid_dir#/proc/}" ;; esac
    done
    echo "$PIDS_CACHE"
}

get_cpu_pct() {
    local pkg="$1"
    [ -z "$pkg" ] && echo "0" && return
    local total_j=0 pid rest j
    for pid in $(get_pids "$pkg"); do
        [ -f "/proc/$pid/stat" ] || continue
        rest=$(cut -d')' -f2- "/proc/$pid/stat" 2>/dev/null)
        [ -n "$rest" ] || continue
        j=$(echo "$rest" | awk '{print $12+$13}' 2>/dev/null)
        case "$j" in ''|*[!0-9]*) j=0 ;; esac
        total_j=$((total_j + j))
    done
    local now=$(date +%s)
    local prev_pkg="" prev_j=0 prev_ts=0
    if [ -f "$COLL_STATE" ]; then
        prev_pkg=$(cut -d'|' -f1 "$COLL_STATE" 2>/dev/null)
        prev_j=$(cut -d'|' -f2 "$COLL_STATE" 2>/dev/null)
        prev_ts=$(cut -d'|' -f3 "$COLL_STATE" 2>/dev/null)
    fi
    echo "${pkg}|${total_j}|${now}" > "${COLL_STATE}.tmp.$$" 2>/dev/null && mv "${COLL_STATE}.tmp.$$" "$COLL_STATE" 2>/dev/null
    case "$prev_j" in ''|*[!0-9]*) prev_j=0 ;; esac
    case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
    local elapsed=$((now - prev_ts))
    local delta=$((total_j - prev_j))
    if [ "$prev_pkg" != "$pkg" ] || [ "$elapsed" -le 0 ] || [ "$delta" -lt 0 ]; then
        echo "0"
        return
    fi
    local cpu=$((delta / elapsed))
    [ "$cpu" -gt 100 ] && cpu=100
    echo "$cpu"
}

get_gpu() {
    local load=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d '% \r\t')
    case "$load" in ''|*[!0-9]*) load=0 ;; esac
    [ "$load" -lt 0 ] 2>/dev/null && load=0
    [ "$load" -gt 100 ] 2>/dev/null && load=100
    echo "$load"
}

get_temp() {
    # v3.1.1: 修复假高温污染。旧实现取所有 thermal_zone*/temp 原始值最大/1000,
    # 会把 lmh-dcvs-* (限频管理, 恒报 75000) 误采成 75°C 写进样本特征,
    # 导致训练标签被高温惩罚污染 (k 全被压到最低)。
    # 现在只统计真正的温度传感器 (-tz/-usr/含therm/battery/bms),
    # 单位归一化 (毫摄氏度/十分之一度/摄氏度) + [10,90]°C 范围过滤。
    local max_t=0 t zone type c
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$zone" ] || continue
        type=$(cat "${zone%/temp}/type" 2>/dev/null)
        case "$type" in
            *-tz|*-usr|*therm*|battery|bms) ;;
            *) continue ;;
        esac
        t=$(cat "$zone" 2>/dev/null)
        case "$t" in ''|*[!0-9]*) continue ;; esac
        [ "$t" -le 0 ] && continue
        c=0
        if [ "$t" -ge 10000 ] && [ "$t" -le 150000 ]; then
            c=$((t / 1000))                     # 毫摄氏度: 48000 -> 48°C
        elif [ "$t" -ge 100 ] && [ "$t" -le 1500 ]; then
            c=$(( (t + 5) / 10 ))               # 十分之一度: 480 -> 48°C
        elif [ "$t" -ge 10 ] && [ "$t" -le 150 ]; then
            c=$t                                # 摄氏度
        fi
        [ "$c" -ge 10 ] && [ "$c" -le 90 ] && [ "$c" -gt "$max_t" ] && max_t=$c
    done
    if [ "$max_t" -le 0 ]; then
        # 回退: 电池温度
        t=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
        case "$t" in ''|*[!0-9]*) ;;
            *)
                [ "$t" -ge 100 ] && [ "$t" -le 1500 ] && max_t=$(( (t + 5) / 10 ))
                [ "$t" -ge 10000 ] && [ "$t" -le 150000 ] && max_t=$((t / 1000))
            ;;
        esac
    fi
    echo "$max_t"
}

get_batt() {
    cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "50"
}

get_charging() {
    local st=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown")
    case "$st" in Charging|Charging*) echo "1" ;; *) echo "0" ;; esac
}

get_screen() {
    # v3.1 fix: 主循环已取过前台 app, 直接传入, 不再重复 dumpsys
    # (旧实现每轮调用两次 dumpsys, 是卡死/开销翻倍的主要来源)
    local pkg="$1"
    [ -z "$pkg" ] && pkg=$(get_fg_app)
    case "$pkg" in
        ""|"android"*|"com.android.systemui"*) echo "0" ;;
        *) echo "1" ;;
    esac
}

get_threads() {
    local pkg="$1"
    [ -z "$pkg" ] && echo "0" && return
    local total=0 pid t
    for pid in $(get_pids "$pkg"); do
        [ -d "/proc/$pid/task" ] || continue
        for t in /proc/$pid/task/[0-9]*; do
            [ -d "$t" ] && total=$((total + 1))
        done
    done
    echo "$total"
}

get_mem() {
    local pkg="$1"
    [ -z "$pkg" ] && echo "0" && return
    local total=0 pid mem
    for pid in $(get_pids "$pkg"); do
        [ -d "/proc/$pid" ] || continue
        mem=$(cat "/proc/$pid/status" 2>/dev/null | grep VmRSS | awk '{print $2}')
        [ -n "$mem" ] && total=$((total + mem))
    done
    echo $((total / 1024))
}

get_mode() {
    cat "$MODDIR/config/current_mode" 2>/dev/null || echo "balanced"
}

update_fg_duration() {
    local pkg="$1"
    local now=$(date +%s)
    local start_pkg="" start_ts=0
    if [ -f "$FG_START_FILE" ]; then
        start_pkg=$(cut -d'|' -f1 "$FG_START_FILE" 2>/dev/null)
        start_ts=$(cut -d'|' -f2 "$FG_START_FILE" 2>/dev/null)
    fi
    case "$start_ts" in ''|*[!0-9]*) start_ts=0 ;; esac

    if [ "$start_pkg" != "$pkg" ]; then
        echo "${pkg}|${now}" > "${FG_START_FILE}.tmp.$$" 2>/dev/null && mv "${FG_START_FILE}.tmp.$$" "$FG_START_FILE" 2>/dev/null
        echo "0"
    else
        local dur=$((now - start_ts))
        echo "$dur"
    fi

    local dur_val=0
    if [ "$start_pkg" = "$pkg" ]; then
        dur_val=$((now - start_ts))
    fi
    echo "$dur_val" > "${FG_DUR_FILE}.tmp.$$" 2>/dev/null && mv "${FG_DUR_FILE}.tmp.$$" "$FG_DUR_FILE" 2>/dev/null
}

# 写入完整状态快照供 nn_infer.sh 读取（修正 v2.1.1）:
# 格式: pkg|jiffies|ts|threads|mem|cpu
#   原格式只有 pkg|jiffies|ts (前3列), nn_infer 曾把第3列(时间戳)误当 CPU 使用。
#   get_cpu_pct 已把前3列更新为本轮值, 这里补上 threads/mem/cpu。
write_coll_state() {
    local _jiffies=$(cut -d'|' -f2 "$COLL_STATE" 2>/dev/null)
    local _ts=$(cut -d'|' -f3 "$COLL_STATE" 2>/dev/null)
    case "$_jiffies" in ''|*[!0-9]*) _jiffies=0 ;; esac
    case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
    echo "${pkg}|${_jiffies}|${_ts}|${threads}|${mem}|${cpu}" > "${COLL_STATE}.tmp.$$" 2>/dev/null \
        && mv "${COLL_STATE}.tmp.$$" "$COLL_STATE" 2>/dev/null
}

# ============ v3.0: 线程快照采样 ============
# 12 类线程语义 (与训练端 train_thread 一致)
thread_type() {
    case "$1" in
        RenderThread|GLThread|UnityRender|SurfaceFlinger|GrWorker) echo 0 ;;
        GpuThread|GPU*) echo 1 ;;
        HwBinder*|Binder*|binder*) echo 2 ;;
        main|ui|UiThread) echo 3 ;;
        AudioThread|AudioTrack|AudioFlinger) echo 4 ;;
        CodecThread|OMX*|VideoDecoder|MediaCodec|NuPlayer) echo 5 ;;
        Netd|OkHttp|Socket*|DNS*) echo 6 ;;
        SQLite|DB-*|GreenDao) echo 7 ;;
        GC|Finalizer|HeapTaskDaemon|ReferenceQueue|Daemon) echo 8 ;;
        Jit*|Compiler*|dex2oat) echo 9 ;;
        "Signal Catcher"|JDWP|Perf*|Sys*) echo 10 ;;
        *) echo 11 ;;
    esac
}

# 字符串 hash 8 位 (h*31+c, 与训练端 python 一致)
str_hash8() {
    local s="$1" h=0 byte bits="" i=0
    for byte in $(printf '%s' "$s" | od -An -tu1 2>/dev/null); do
        case "$byte" in ''|*[!0-9]*) continue ;; esac
        h=$(( (h * 31 + byte) & 0xFFFFFFFF ))
    done
    while [ $i -lt 8 ]; do
        bits="$bits $(( (h >> i) & 1 ))"
        i=$((i+1))
    done
    echo "$bits"
}

# 抓前台 app 的 top-6 线程 [name, cpu%] 并生成 21 维特征, 写 .threads_snapshot
# 格式: name|cpu%|21维特征 (cpu/100, 类型onehot12, 名hash8)
THREADS_PREV="$DATA_DIR/.threads_prev"
write_threads_snapshot() {
    local pkg="$1"
    [ -z "$pkg" ] && return
    local now=$(date +%s)
    local prev_ts=0
    # v3.3.1 fix: cut 会对 PREV 每一行取字段 -> 多行输出 -> prev_ts 含换行
    # -> [ -gt ] 整数比较失败 -> 快照永不写入。必须 head -1 只取时间戳。
    [ -f "$THREADS_PREV" ] && prev_ts=$(head -1 "$THREADS_PREV" 2>/dev/null)
    local lines=""
    local pid t tid tname j
    for pid in $(get_pids "$pkg"); do
        [ -d "/proc/$pid/task" ] || continue
        for t in /proc/$pid/task/[0-9]*; do
            [ -d "$t" ] || continue
            tid=${t##*/}
            tname=$(cat "$t/comm" 2>/dev/null)
            rest=$(cut -d')' -f2- "$t/stat" 2>/dev/null)
            [ -n "$rest" ] || continue
            j=$(echo "$rest" | awk '{print $12+$13}' 2>/dev/null)
            case "$j" in ''|*[!0-9]*) j=0 ;; esac
            lines="$lines
$tname|$tid|$j"
        done
    done
    # v3.3.1 fix: 差分需要上一轮 jiffies, 必须在覆盖 PREV 前读取
    old_prev=""
    if [ -f "$THREADS_PREV" ]; then
        old_prev=$(tail -n +2 "$THREADS_PREV" 2>/dev/null)
    fi
    # 保存本轮快照 (时间戳 + 每行 name|tid|jiffies)
    { echo "$now"; echo "$lines" | tail -n +2; } > "${THREADS_PREV}.tmp.$$" 2>/dev/null \
        && mv "${THREADS_PREV}.tmp.$$" "$THREADS_PREV"
    # 与上轮差分计算 cpu%, 取 top-6
    local out=""
    if [ -n "$prev_ts" ] && [ "$prev_ts" -gt 0 ] 2>/dev/null; then
        local elapsed=$((now - prev_ts))
        [ "$elapsed" -le 0 ] && elapsed=1
        # v3.3.1 fix: 管道 while 是子 shell (非函数), mksh 下 local 报错导致循环体
        # 不执行 -> out 恒空 -> .threads_snapshot 永不写入。全部去掉 local。
        # 同时修 cpu 差分: 旧版 (tj-0)/elapsed 用累计 jiffies 会高估到 100。
        out=$(echo "$lines" | tail -n +2 | while IFS='|' read -r tn tid tj; do
            case "$tj" in ''|*[!0-9]*) tj=0 ;; esac
            prev_j=0
            prev_j=$(printf '%s\n' "$old_prev" | awk -F'|' -v t="$tid" '$2==t {print $3; exit}')
            case "$prev_j" in ''|*[!0-9]*) prev_j=0 ;; esac
            delta=$((tj - prev_j))
            [ "$delta" -lt 0 ] && delta=0
            cpu_pct=$(( delta / elapsed ))
            [ "$cpu_pct" -gt 100 ] && cpu_pct=100
            ttype=$(thread_type "$tn")
            thash=$(str_hash8 "$tn")
            feat="$((cpu_pct))/100"
            c=0; i=0
            for c in 0 1 2 3 4 5 6 7 8 9 10 11; do
                [ "$c" = "$ttype" ] && feat="$feat|1" || feat="$feat|0"
            done
            for c in $thash; do feat="$feat|$c"; done
            echo "$tn|$cpu_pct|$feat"
        done | sort -t'|' -k2 -rn | head -6)
    fi
    if [ -n "$out" ]; then
        echo "$out" > "${THREADS_SNAP}.tmp.$$" 2>/dev/null && mv "${THREADS_SNAP}.tmp.$$" "$THREADS_SNAP"
    fi
}

# ============ v3.0: 帧率反馈采集 (帧时间方差) ============
# v3.2 fix: 帧率反馈采集失败 -> .traw 里 fn=0/fzero=1 默认值 -> 训练端 0% 有效标签
#   (表现为 loss 恒 0.0000, 模型是随机初始化导出, 等于没训)
# v3.2.2 fix: 3 个后续问题
#   1) 失败日志每 5s 刷一条 -> frame_log() 30s 节流
#   2) 视频场景 (bilibilihd 播放中) 也报 "帧数不足" -> 旧逻辑取"第一个 ≥10 帧"的候选 layer,
#      会选到 UI/弹幕层(帧少)而非视频渲染层 -> 改为遍历所有候选, 选"有效帧数最多"的 layer
#   3) 微信等报 "no layer matching" -> dumpsys SurfaceFlinger --list 在 SF 忙时 5s 被掐断,
#      只输出前半段(系统层), 后半段 app 层没打出来 -> --list 超时放宽到 10s
# 输出: 有效帧数|平均帧时间ms|方差ms²|0帧比例  (写入 .frame_stats)
# 规则: 有效帧<10 或 0帧比例>30% 时训练端跳过帧率反馈
get_frame_stats() {
    local pkg="$1"
    [ -z "$pkg" ] && return 1
    # 前台 app 切换 -> 旧帧统计作废
    local owner=""
    [ -f "$FRAME_STATS_OWNER" ] && owner=$(cat "$FRAME_STATS_OWNER" 2>/dev/null)
    if [ "$owner" != "$pkg" ]; then
        rm -f "$FRAME_STATS" 2>/dev/null
        echo "$pkg" > "${FRAME_STATS_OWNER}.tmp.$$" 2>/dev/null && mv "${FRAME_STATS_OWNER}.tmp.$$" "$FRAME_STATS_OWNER" 2>/dev/null
    fi
    local list layer raw candidates
    # v3.2.2: --list 超时 5s -> 10s (SF 忙时输出几千行会被 5s 掐断, 造成假阴性 "no layer matching")
    if command -v timeout >/dev/null 2>&1; then
        list=$(timeout 10 dumpsys SurfaceFlinger --list 2>/dev/null)
    else
        list=$(dumpsys SurfaceFlinger --list 2>/dev/null)
    fi
    [ -z "$list" ] && { frame_log "[frame] SurfaceFlinger --list empty/timeout for $pkg"; return 1; }
    # 候选1: 完整包名固定串匹配, 优先带 # 的 layer (真实渲染 surface)
    candidates=$(echo "$list" | grep -iF "$pkg" | grep -F '#')
    # 候选2: 完整包名匹配任意 layer
    [ -z "$candidates" ] && candidates=$(echo "$list" | grep -iF "$pkg" | head -8)
    # 候选3: 包名去掉最后一段 (兼容 layer 名省略 activity 后缀)
    [ -z "$candidates" ] && candidates=$(echo "$list" | grep -iF "${pkg%.*}" | head -8)
    [ -z "$candidates" ] && { frame_log "[frame] no layer matching $pkg"; return 1; }
    # v3.2.2: 遍历所有候选, 选"有效帧数最多"的 layer
    local n best_n=0 best_raw="" best_layer=""
    for layer in $candidates; do
        [ -n "$layer" ] || continue
        # 只取 3 列纯数字行 (层名/刷新周期/表头自动跳过), 最多 128 行
        raw=$(dumpsys_t SurfaceFlinger --latency "$layer" 2>/dev/null | \
              awk 'NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {print; if (++c>=128) exit}')
        [ -z "$raw" ] && continue
        n=$(echo "$raw" | awk '{a=$2+0; if(a>0) c++} END {print c+0}')
        if [ "${n:-0}" -gt "$best_n" ] 2>/dev/null; then
            best_n=$n; best_raw=$raw; best_layer=$layer
        fi
    done
    if [ "${best_n:-0}" -ge 10 ] 2>/dev/null && [ -n "$best_raw" ]; then
        echo "$best_raw" | awk '
            BEGIN { n=0; prev=0; sum=0; sum2=0; zeros=0; total=0 }
            { total++; actual=$2+0
              if (actual <= 0) { zeros++; next }
              if (prev > 0) { dt=actual-prev; if (dt>0 && dt<1000000000) { n++; sum+=dt; sum2+=dt*dt } }
              prev=actual }
            END { if (total==0) { print "0|0|0|1"; exit }
                  if (n<10) { printf "%d|0|0|%.2f\n", n, zeros/total; exit }
                  avg=sum/n; var=sum2/n-avg*avg; if (var<0) var=0
                  printf "%d|%.2f|%.2f|%.2f\n", n, avg/1000000, var/1e12, zeros/total }' \
            > "${FRAME_STATS}.tmp.$$" 2>/dev/null && mv "${FRAME_STATS}.tmp.$$" "$FRAME_STATS"
        return 0
    fi
    frame_log "[frame] no layer with >=10 valid frames for $pkg (best=$best_n)"
    return 1
}

# ============ v3.3: 每核使用率采集 (供模型感知小核负载分布/均衡) ============
# 输出: c0|c1|...|c7 (使用率%, 0-100), 写入 .core_load
# 基于 /proc/stat cpuN 行的 (total-idle)/total 差分; 首轮无差分输出 0
get_core_load() {
    local now
    now=$(date +%s)
    local prev_ts=0
    [ -f "$CORE_LOAD_PREV" ] && prev_ts=$(head -1 "$CORE_LOAD_PREV" 2>/dev/null)
    case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
    # 存当前快照 (时间戳 + cpuN idle total)
    { echo "$now"; awk '/^cpu[0-7] / { split($0,a," "); idle=a[5]+a[6]; tot=0; for(i=2;i<=8;i++) tot+=a[i]; print a[1], idle, tot }' /proc/stat 2>/dev/null; } \
        > "${CORE_LOAD_PREV}.tmp.$$" 2>/dev/null && mv "${CORE_LOAD_PREV}.tmp.$$" "$CORE_LOAD_PREV"
    if [ "$prev_ts" -le 0 ] || [ $((now - prev_ts)) -le 0 ] 2>/dev/null; then
        echo "0|0|0|0|0|0|0|0" > "${CORE_LOAD}.tmp.$$" 2>/dev/null && mv "${CORE_LOAD}.tmp.$$" "$CORE_LOAD"
        return 0
    fi
    local elapsed=$((now - prev_ts))
    local out
    out=$(awk -v prevfile="$CORE_LOAD_PREV" -v el="$elapsed" '
        NR==FNR && /^cpu[0-7] / { pn[$1]=$2; pt[$1]=$3; next }
        FNR>1 && /^cpu[0-7] / {
            di=$2-pn[$1]; dt=$3-pt[$1]
            u = (dt<=0) ? 0 : (dt-di)*100/dt
            if (u<0) u=0; if (u>100) u=100
            res = res sprintf("%s%.0f", (res?"|":""), u)
        }
        END { print res }' "$CORE_LOAD_PREV" /proc/stat 2>/dev/null)
    case "$out" in ''|*[!0-9|]*) out="0|0|0|0|0|0|0|0" ;; esac
    echo "$out" > "${CORE_LOAD}.tmp.$$" 2>/dev/null && mv "${CORE_LOAD}.tmp.$$" "$CORE_LOAD"
}

while true; do
    rotate_data

    pkg=$(get_fg_app)
    [ -z "$pkg" ] && { sleep 1; continue; }

    ts=$(date +%s)
    cpu=$(get_cpu_pct "$pkg")
    gpu=$(get_gpu)
    temp=$(get_temp)
    batt=$(get_batt)
    chg=$(get_charging)
    screen=$(get_screen "$pkg")
    threads=$(get_threads "$pkg")
    mem=$(get_mem "$pkg")
    mode=$(get_mode)
    fgdur=$(update_fg_duration "$pkg")
    hour=$(date +%H)
    today=$(date +%Y%m%d)
    OUTFILE="$DATA_DIR/${today}.raw"

    atomic_append "${ts}|${pkg}|${cpu}|${gpu}|${temp}|${batt}|${chg}|${screen}|${threads}|${mem}|${mode}|${fgdur}|${hour}"
    write_coll_state

    # v3.0: 每 5 秒采样一次线程快照 + 帧率反馈 (dumpsys/SurfaceFlinger 开销大, 不每轮跑)
    if [ $((ts - V3_LAST)) -ge 5 ] 2>/dev/null; then
        V3_LAST=$ts
        write_threads_snapshot "$pkg"
        get_frame_stats "$pkg"
        get_core_load
        # 追加历史记录到 YYYYMMDD.traw (供 train_thread.py 训练)
        # 格式: ts|pkg|聚合10|fn|favg|fvar|fzero|t1name|t1cpu|...|t6name|t6cpu
        traw="$DATA_DIR/$(date +%Y%m%d).traw"
        # v3.2 fix: 只有帧统计属于当前 app 且 <30s 新鲜才采用, 否则用默认值
        # (旧实现: 换 app 后仍复用上个 app 的 .frame_stats -> 用错的帧反馈标错标签)
        fn=0 favg=0 fvar=0 fzero=1
        if [ -f "$FRAME_STATS" ]; then
            fs_age=$(( $(date +%s) - $(stat -c %Y "$FRAME_STATS" 2>/dev/null || echo 0) ))
            fs_owner=""
            [ -f "$FRAME_STATS_OWNER" ] && fs_owner=$(cat "$FRAME_STATS_OWNER" 2>/dev/null)
            if [ "$fs_owner" = "$pkg" ] && [ "$fs_age" -le 30 ] 2>/dev/null; then
                IFS='|' read -r fn favg fvar fzero < "$FRAME_STATS" 2>/dev/null
                case "$fn" in ''|*[!0-9]*) fn=0 ;; esac
                case "$favg" in ''|*[!0-9.]*) favg=0 ;; esac
                case "$fvar" in ''|*[!0-9.]*) fvar=0 ;; esac
                case "$fzero" in ''|*[!0-9.]*) fzero=1 ;; esac
            fi
        fi
        # 从快照取最多 6 线程
        tline="$traw_line"
        tstr=""
        if [ -f "$THREADS_SNAP" ]; then
            tstr=$(head -6 "$THREADS_SNAP" 2>/dev/null | awk -F'|' '{printf "%s|%s|", $1, $2}')
        fi
        # 补足 6 组 (空槽用 "none|0")
        tcount=$(echo "$tstr" | awk -F'|' '{print NF/2}')
        while [ "${tcount:-0}" -lt 6 ] 2>/dev/null; do tstr="${tstr}none|0|"; tcount=$((tcount + 1)); done
        # v3.3: traw 行尾追加 8 核负载 (训练端解析 parts[-8:], 旧数据无则置 0)
        core_str="0|0|0|0|0|0|0|0"
        if [ -f "$CORE_LOAD" ]; then
            core_str=$(cat "$CORE_LOAD" 2>/dev/null)
            case "$core_str" in ''|*[!0-9|]*) core_str="0|0|0|0|0|0|0|0" ;; esac
        fi
        echo "${ts}|${pkg}|${cpu}|${gpu}|${temp}|${batt}|${chg}|${screen}|${threads}|${mem}|${hour}|${fgdur}|${fn}|${favg}|${fvar}|${fzero}|${tstr}${core_str}" >> "$traw" 2>/dev/null
    fi

    # v3.1 fix: 进度心跳。watchdog 用 .hb_done 判断采集器是否"活着但卡死"
    # (例如某轮 dumpsys//proc 读取阻塞), 超过阈值会杀掉重启。
    echo "$ts" > "$DATA_DIR/.hb_done" 2>/dev/null

    sleep 1
done