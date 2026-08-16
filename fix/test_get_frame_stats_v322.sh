#!/bin/bash
export PATH="/tmp/fr_bin:$PATH"     # mock 外部 dumpsys
DATA_DIR="/tmp/fr_test2"; rm -rf "$DATA_DIR"; mkdir -p "$DATA_DIR"
FRAME_STATS="$DATA_DIR/.frame_stats"
FRAME_STATS_OWNER="$DATA_DIR/.frame_stats_owner"
FRAME_LOG_STAMP="$DATA_DIR/.frame_log_stamp"
LOG="/tmp/fr_test2.log"; rm -f "$LOG"
log_msg() { echo "$1" >> "$LOG"; }
dumpsys_t() { timeout 5 dumpsys "$@"; }

frame_log() {
    local now=$(date +%s) last=0
    [ -f "$FRAME_LOG_STAMP" ] && last=$(cat "$FRAME_LOG_STAMP" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((now - last)) -ge 30 ] 2>/dev/null; then
        echo "$now" > "${FRAME_LOG_STAMP}.tmp.$$" 2>/dev/null && mv "${FRAME_LOG_STAMP}.tmp.$$" "$FRAME_LOG_STAMP" 2>/dev/null
        log_msg "$1"
    fi
}

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



echo "== Test A: 视频 app (UI层 n=5 + 视频层 n=60) -> 应选视频渲染层"
unset SLOW_LIST
get_frame_stats "tv.danmaku.bilibilihd"
echo "rc=$?  .frame_stats=$(cat "$FRAME_STATS" 2>/dev/null)  <- 期望 avg≈33.3ms (30fps)"

echo
echo "== Test B: 微信 (低频渲染) -> 输出 stats, zero 高留给训练端判定"
get_frame_stats "com.tencent.mm"
echo "rc=$?  .frame_stats=$(cat "$FRAME_STATS" 2>/dev/null)  <- 期望 n≈19, zero≈0.84"

echo
echo "== Test C: 日志节流 -> 换新包名连打 5 次失败, 30s 内只应 1 条"
rm -f "$LOG"
get_frame_stats "com.notexist.app"; get_frame_stats "com.notexist.app"
get_frame_stats "com.notexist.app"; get_frame_stats "com.notexist.app"
get_frame_stats "com.notexist.app"
echo "日志条数: $(wc -l < "$LOG" 2>/dev/null || echo 0)  <- 期望 1 (no layer matching)"

echo
echo "== Test D: SF 忙时 --list 慢 7s -> 真 timeout: 5s 被掐断 / 10s 成功"
export SLOW_LIST=1
t0=$(date +%s); l5=$(timeout 5 dumpsys SurfaceFlinger --list 2>/dev/null); t1=$(date +%s)
echo "  timeout 5 : 耗时 $((t1-t0))s, 行数 $(echo "$l5" | wc -l)  <- 期望 0 (被掐断)"
t0=$(date +%s); l10=$(timeout 10 dumpsys SurfaceFlinger --list 2>/dev/null); t1=$(date +%s)
echo "  timeout 10: 耗时 $((t1-t0))s, 行数 $(echo "$l10" | wc -l)  <- 期望 6 (完成)"
unset SLOW_LIST
echo "  完整链路 (list 7s + latency):"; t0=$(date +%s); get_frame_stats "tv.danmaku.bilibilihd"; t1=$(date +%s)
echo "    rc=$? 耗时 $((t1-t0))s .frame_stats=$(cat "$FRAME_STATS" 2>/dev/null)"
