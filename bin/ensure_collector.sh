#!/system/bin/sh
################################################################################
# ensure_collector.sh - 幂等启动 NN 数据采集器
#
# 三个启动阶段都会调用 (post-fs-data 早期 / service 中期 / service 周期守护):
#   1. 已运行 -> 直接退出 (防重复)
#   2. 未运行 -> 拉起 collector.sh (nohup 后台, 日志可查)
#
# 用法: sh bin/ensure_collector.sh
################################################################################

MODDIR="/data/adb/modules/sd730-scheduler"
LOG="/data/local/tmp/sd730-collector.log"

# 已运行则跳过
if pgrep -f "bin/collector.sh" >/dev/null 2>&1; then
    exit 0
fi

# 记录启动时机, 便于排查
echo "[ensure] $(date '+%Y-%m-%d %H:%M:%S') stage=$1 starting collector" >> "$LOG" 2>/dev/null
nohup sh "$MODDIR/bin/collector.sh" >> "$LOG" 2>&1 &
exit 0
