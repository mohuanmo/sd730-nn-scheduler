#!/bin/bash
# 本地测试: 改进版 get_frame_stats (mock dumpsys SurfaceFlinger)
# 用法: bash test_get_frame_stats.sh

DATA_DIR="/tmp/fr_test"
mkdir -p "$DATA_DIR"
FRAME_STATS="$DATA_DIR/.frame_stats"
FRAME_STATS_OWNER="$DATA_DIR/.frame_stats_owner"

log_msg() { :; }

# ---------------- 改进版 get_frame_stats (POSIX sh, 兼容 mksh) ----------------
get_frame_stats() {
    local pkg="$1"
    [ -z "$pkg" ] && return 1
    # 前台 app 切换 -> 旧帧统计作废 (防跨 app 复用脏数据)
    local owner=""
    [ -f "$FRAME_STATS_OWNER" ] && owner=$(cat "$FRAME_STATS_OWNER" 2>/dev/null)
    if [ "$owner" != "$pkg" ]; then
        rm -f "$FRAME_STATS" 2>/dev/null
        echo "$pkg" > "${FRAME_STATS_OWNER}.tmp.$$" 2>/dev/null && mv "${FRAME_STATS_OWNER}.tmp.$$" "$FRAME_STATS_OWNER" 2>/dev/null
    fi
    local list layer raw candidates
    list=$(dumpsys_t SurfaceFlinger --list 2>/dev/null)
    [ -z "$list" ] && { log_msg "[frame] SurfaceFlinger --list empty/timeout"; return 1; }
    # 候选: 完整包名固定串匹配; 优先带 # 的 Activity/Surface layer
    candidates=$(echo "$list" | grep -iF "$pkg" | grep -F '#')
    [ -z "$candidates" ] && candidates=$(echo "$list" | grep -iF "$pkg" | head -8)
    # 回退: 包名去掉最后一段
    [ -z "$candidates" ] && candidates=$(echo "$list" | grep -iF "${pkg%.*}" | head -8)
    [ -z "$candidates" ] && { log_msg "[frame] no layer matching $pkg"; return 1; }
    local n ok=0
    for layer in $candidates; do
        [ -n "$layer" ] || continue
        # 只取 3 列纯数字行 (跳过 layer 名/刷新周期等表头), 最多 128 行
        raw=$(dumpsys_t SurfaceFlinger --latency "$layer" 2>/dev/null | \
              awk 'NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {print; if (++c>=128) exit}')
        [ -z "$raw" ] && continue
        n=$(echo "$raw" | awk '{a=$2+0; if(a>0) c++} END {print c+0}')
        if [ "${n:-0}" -ge 10 ] 2>/dev/null; then
            echo "$raw" | awk '
                BEGIN { n=0; prev=0; sum=0; sum2=0; zeros=0; total=0 }
                { total++; actual=$2+0
                  if (actual <= 0) { zeros++; next }
                  if (prev > 0) { dt=actual-prev; if (dt>0 && dt<1000000000) { n++; sum+=dt; sum2+=dt*dt } }
                  prev=actual }
                END { if (total==0) { print "0|0|0|1"; exit }
                      if (n<10) { printf "%d|0|0|%.2f\n", n, zeros/total; exit }
                      avg=sum/n; var=sum2/n-avg*avg
                      printf "%d|%.2f|%.2f|%.2f\n", n, avg/1000000, var/1e12, zeros/total }' \
                > "${FRAME_STATS}.tmp.$$" 2>/dev/null && mv "${FRAME_STATS}.tmp.$$" "$FRAME_STATS"
            ok=1; break
        fi
    done
    [ "$ok" = "1" ] || { log_msg "[frame] no layer with >=10 valid frames for $pkg"; return 1; }
    return 0
}
# -----------------------------------------------------------------------------

# ---------------- Mock dumpsys ----------------
LAYER_LIST="com.android.systemui.ImageWallpaper
com.android.systemui/com.android.systemui.ScreenDecorations#0
com.tencent.mm/com.tencent.mm.ui.LauncherUI
com.tencent.mm/com.tencent.mm.ui.LauncherUI#0
com.tencent.mm/com.tencent.mm.plugin.appbrand.ui.AppBrandUI#0
com.tencent.tmgp.sgame/com.tencent.tmgp.sgame.unity3d.UnityPlayerActivity#0
com.android.browser/com.android.browser.BrowserActivity#0"

mk_latency() { # $1=name $2=fps_type
    echo "$1"
    echo "16666667"
    if [ "$2" = "jank" ]; then
        local t=1000000000000 i
        for i in $(seq 1 60); do
            if [ $((i % 3)) = 0 ]; then t=$((t + 50000000)); else t=$((t + 16666667)); fi
            echo "$t $t $t"
        done
    elif [ "$2" = "smooth" ]; then
        local t=1000000000000 i
        for i in $(seq 1 60); do t=$((t + 16666667)); echo "$t $t $t"; done
    elif [ "$2" = "idle" ]; then
        # 静止: 无新帧, actual 全 0
        for i in $(seq 1 60); do echo "0 0 0"; done
    fi
}

dumpsys_t() {
    if [ "$1" = "SurfaceFlinger" ] && [ "$2" = "--list" ]; then
        echo "$LAYER_LIST"
        return 0
    fi
    if [ "$1" = "SurfaceFlinger" ] && [ "$2" = "--latency" ]; then
        local layer="$3"
        case "$layer" in
            *sgame*)  mk_latency "$layer" jank ;;     # 游戏卡顿
            *LauncherUI#0*) mk_latency "$layer" smooth ;; # 微信跑满
            *BrowserActivity#0*) mk_latency "$layer" idle ;; # 静止
            *) echo "" ;;
        esac
        return 0
    fi
    return 0
}

echo "== Test 1: 游戏 (jank) -> 应输出 fn>=10 且 avg>17.5 = 有效卡顿标签"
get_frame_stats "com.tencent.tmgp.sgame"
echo "rc=$?  .frame_stats=$(cat "$FRAME_STATS" 2>/dev/null)"

echo
echo "== Test 2: 微信 (smooth 60fps) -> 有效, avg<=17.5 (跑满)"
get_frame_stats "com.tencent.mm"
echo "rc=$?  .frame_stats=$(cat "$FRAME_STATS" 2>/dev/null)"

echo
echo "== Test 3: 静止页面 (全0帧) -> n<10 -> 应视为无效 (跳过)"
get_frame_stats "com.android.browser"
echo "rc=$?  .frame_stats=$(cat "$FRAME_STATS" 2>/dev/null)"

echo
echo "== Test 4: app 切换清空 -> 换包后 .frame_stats 应为空"
rm -f "$FRAME_STATS"; echo "com.tencent.mm" > "$FRAME_STATS_OWNER"
get_frame_stats "com.android.browser"   # owner 不匹配 -> 先清空
echo "rc=$?  .frame_stats=[$(cat "$FRAME_STATS" 2>/dev/null)] (空=切换后未成功采集, 训练端会用默认值跳过)"

echo
echo "== Test 5: 未知 app -> 无 layer -> rc=1"
get_frame_stats "com.notexist.app"
echo "rc=$?  .frame_stats=[$(cat "$FRAME_STATS" 2>/dev/null)]"
