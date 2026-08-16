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

