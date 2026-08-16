#!/system/bin/sh
################################################################################
# v3_decision.sh - v3.0 线程级绑核决策 (tid 级)
#
# 输入: .coll_state + .threads_snapshot + .frame_stats + model/mlp_v3_*
# 输出: 每行 "tid|score|cpu" 按 score 降序 (模型认为越该绑 big 越靠前)
#       模型不可用/失败 -> 输出 "NO_MODEL" (调用方回退 v2 规则)
################################################################################

MODDIR="/data/adb/modules/sd730-scheduler"
COLL_STATE="$MODDIR/data/collector/.coll_state"
THREADS_SNAP="$MODDIR/data/collector/.threads_snapshot"

[ -f "$MODDIR/model/mlp_v3_enc.txt" ] && [ -f "$MODDIR/model/mlp_v3_scr.txt" ] || { echo "NO_MODEL"; exit 0; }
[ -f "$COLL_STATE" ] || { echo "NO_STATE"; exit 0; }
[ -f "$THREADS_SNAP" ] || { echo "NO_THREADS"; exit 0; }

# 前台包名
PKG=$(cut -d'|' -f1 "$COLL_STATE" 2>/dev/null)

# 1) nn_infer_v3.sh 给出 name|cpu|score|hot
SCORES=$("$MODDIR/bin/nn_infer_v3.sh" 2>/dev/null | grep -v '^K=')

# 2) 枚举 tid|name (前台 app 所有线程)
get_pids() {
    local pkg="$1" pid_dir cmd
    [ -z "$pkg" ] && return
    for pid_dir in /proc/[0-9]*; do
        cmd=""
        IFS= read -r cmd < "$pid_dir/cmdline" 2>/dev/null
        case "$cmd" in "$pkg"|"$pkg":*) echo "${pid_dir#/proc/}" ;; esac
    done
}

# 3) join: tid|name + name|score -> tid|score, 按 score 降序 (无分数 tid 排后)
{
    for pid in $(get_pids "$PKG"); do
        [ -d "/proc/$pid/task" ] || continue
        for t in /proc/$pid/task/[0-9]*; do
            [ -d "$t" ] || continue
            tid=${t##*/}
            name=""
            IFS= read -r name < "$t/comm" 2>/dev/null
            score=$(echo "$SCORES" | awk -F'|' -v n="$name" '$1==n {print $3; exit}')
            case "$score" in ''|*[!0-9.]*) score=0.0 ;; esac
            cpu=$(echo "$SCORES" | awk -F'|' -v n="$name" '$1==n {print $2; exit}')
            case "$cpu" in ''|*[!0-9]*) cpu=0 ;; esac
            printf "%s|%s|%s\n" "$tid" "$score" "$cpu"
        done
    done
} | sort -t'|' -k2,2 -rn
