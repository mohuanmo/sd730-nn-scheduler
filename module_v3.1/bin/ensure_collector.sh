#!/system/bin/sh
################################################################################
# ensure_collector.sh - 幂等启动 NN 数据采集器 (v3.1 merge fix)
#
# 修复要点 (针对"每次开机采集器不启动, 必须手动跑 collector.sh"的问题):
#  1. 不再只依赖 pgrep -f 判活: 改用 PID 文件 + /proc 存活/身份/僵尸校验。
#     旧实现里 pgrep 一旦误匹配 (僵尸进程、其他进程 cmdline 含同名串) 就会
#     误判"已在运行"而直接跳过, 采集器永远起不来;
#  2. 日志目录缺失时 mkdir -p, 日志写入失败也不阻断启动 (降级 /dev/null),
#     避免 post-fs-data 早期 /data/local/tmp 尚未就绪时静默启动失败;
#  3. 无 nohup 的 ROM 也能后台运行 (纯 & 兜底);
#  4. mkdir 原子锁: 防止多入口 (post-fs-data / service / watchdog / CLI)
#     并发重复拉起; 锁若因持有者被杀而残留且采集器未运行, 60s 后自动接管;
#  5. 本脚本不依赖 functions.sh, 可在 service.sh / post-fs-data.sh 最先执行,
#     即使后续初始化卡住, 采集器也已先起来。
#
# 调用时机 (全部幂等, 已运行则直接退出):
#   post-fs-data.sh : early
#   service.sh      : service / watchdog (30s 周期)
#   functions.sh    : sourced (任意入口 source 均会触发自愈)
#
# 用法: sh bin/ensure_collector.sh [stage]
################################################################################

MODDIR="/data/adb/modules/sd730-scheduler"
BIN="$MODDIR/bin/collector.sh"
DATA_DIR="$MODDIR/data/collector"
HB="$DATA_DIR/.hb_done"               # 采集器每轮完成时写的时间戳 (进度心跳)
LOG_DIR="/data/local/tmp"
LOG="$LOG_DIR/sd730-collector.log"
PIDFILE="$LOG_DIR/sd730-collector.pid"
LOCK="$LOG_DIR/.sd730-collector.lock"

# watchdog 卡死判定阈值 (秒): 健康采集器一轮 <10s, 留足余量
STUCK_AFTER=120

[ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null

# 写日志; 目录/文件不可写时静默降级 (绝不因日志失败而中断启动)
wlog() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null || true
}

# 判断 pid 是否为"活着的、且属于本模块"的 collector
pid_is_live_collector() {
    local pid="$1" state
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -r "/proc/$pid/stat" ] || return 1
    # 僵尸进程会占着进程表不放且 cmdline 仍可读, 必须显式排除,
    # 否则 pgrep/PID文件 会误判"在运行"导致永远不再拉起。
    state=$(cut -d' ' -f3 "/proc/$pid/stat" 2>/dev/null)
    [ "$state" = "Z" ] && return 1
    # 身份校验: cmdline 必须真的指向 bin/collector.sh
    grep -q "bin/collector.sh" "/proc/$pid/cmdline" 2>/dev/null || return 1
    return 0
}

# 采集器是否已在运行 (PID 文件优先; pgrep 兜底, 排除僵尸与自身)
collector_alive() {
    local pid=""
    if [ -f "$PIDFILE" ]; then
        pid=$(cat "$PIDFILE" 2>/dev/null)
        if pid_is_live_collector "$pid"; then
            return 0
        fi
        rm -f "$PIDFILE" 2>/dev/null   # 陈旧/僵尸 -> 清除后重新拉起
    fi
    if command -v pgrep >/dev/null 2>&1; then
        local p
        for p in $(pgrep -f "bin/collector.sh" 2>/dev/null); do
            [ "$p" = "$$" ] && continue
            pid_is_live_collector "$p" && return 0
        done
    fi
    return 1
}

# ---- 原子锁: 只允许一个调用方真正执行拉起 ----
LOCKED=0
if mkdir "$LOCK" 2>/dev/null; then
    LOCKED=1
else
    # 锁被占用。若采集器确实没在跑且锁已陈旧 (持有者被 SIGKILL 残留),
    # 接管并重新拉起; 否则说明另一入口正在拉起, 直接退出。
    if ! collector_alive; then
        l_age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
        if [ "${l_age:-0}" -gt 60 ] 2>/dev/null; then
            rmdir "$LOCK" 2>/dev/null
            mkdir "$LOCK" 2>/dev/null && LOCKED=1
        fi
    fi
fi

if [ "$LOCKED" = "1" ]; then
    # ---- watchdog: 卡死检测 (进程活着但长期无进度 -> 杀掉重启) ----
    # .hb_done 每轮循环完成时更新; 超过 STUCK_AFTER 秒未更新说明被某轮
    # dumpsys//proc 读取永久阻塞。仅对身份匹配的 collector 下手, 绝不误杀。
    if [ "$1" = "watchdog" ] && [ -f "$HB" ] && [ -f "$PIDFILE" ]; then
        hb_pid=$(cat "$PIDFILE" 2>/dev/null)
        hb_ts=$(cat "$HB" 2>/dev/null)
        case "$hb_ts" in ''|*[!0-9]*) hb_ts=0 ;; esac
        now=$(date +%s)
        if [ "$hb_ts" -gt 0 ] 2>/dev/null && [ $((now - hb_ts)) -gt "$STUCK_AFTER" ] 2>/dev/null \
           && pid_is_live_collector "$hb_pid"; then
            wlog "ensure: watchdog killed STUCK collector pid=$hb_pid (hb ${hb_ts}, now ${now}, age $((now - hb_ts))s > ${STUCK_AFTER}s)"
            kill "$hb_pid" 2>/dev/null
            sleep 1
            kill -9 "$hb_pid" 2>/dev/null
            rm -f "$PIDFILE" 2>/dev/null
        fi
    fi
    # 拿到锁后再复查一次, 消除与上一个入口之间的竞态
    if ! collector_alive; then
        wlog "ensure: stage=$1 starting collector"
        if command -v nohup >/dev/null 2>&1; then
            nohup sh "$BIN" >> "$LOG" 2>&1 &
        else
            sh "$BIN" >> "$LOG" 2>&1 &
        fi
        echo $! > "$PIDFILE" 2>/dev/null
    fi
    rmdir "$LOCK" 2>/dev/null
fi

exit 0
