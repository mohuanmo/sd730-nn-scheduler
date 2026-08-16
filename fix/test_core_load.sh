#!/bin/bash
DATA_DIR="/tmp/core_test"; rm -rf "$DATA_DIR"; mkdir -p "$DATA_DIR"
CORE_LOAD="$DATA_DIR/.core_load"
CORE_LOAD_PREV="$DATA_DIR/.core_load_prev"
log_msg() { :; }

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


t0=$(date +%s)
cat > "$CORE_LOAD_PREV" <<P
$t0
cpu0 800 1000
cpu1 700 1000
cpu2 600 1000
cpu3 500 1000
cpu4 800 1000
cpu5 700 1000
cpu6 600 1000
cpu7 500 1000
P
cat > /tmp/cur_stat <<C
cpu 0 0 0 0 0 0 0 0 0 0
cpu0 210 0 0 890 0 0 0
cpu1 330 0 0 770 0 0 0
cpu2 450 0 0 650 0 0 0
cpu3 570 0 0 530 0 0 0
cpu4 290 0 0 810 0 0 0
cpu5 300 0 0 800 0 0 0
cpu6 420 0 0 680 0 0 0
cpu7 600 0 0 500 0 0 0
intr 0
ctxt 0
C
out=$(awk -v prevfile="$CORE_LOAD_PREV" '
    NR==FNR && /^cpu[0-7] / { pn[$1]=$2; pt[$1]=$3; next }
    FNR>1 && /^cpu[0-7] / {
        di=$5-pn[$1]; dt=($2+$3+$4+$5+$6+$7+$8)-pt[$1]
        u = (dt<=0) ? 0 : (dt-di)*100/dt
        if (u<0) u=0; if (u>100) u=100
        res = res sprintf("%s%.0f", (res?"|":""), u)
    }
    END { print res }' "$CORE_LOAD_PREV" /tmp/cur_stat 2>/dev/null)
echo "结果: $out"
echo "期望: 10|30|50|70|90|0|20|100"
