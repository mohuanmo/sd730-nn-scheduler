#!/usr/bin/env python3
"""
SD730 Neural Scheduler v3.0 - Patch functions.sh for thread-level binding
插入点: tpin 引擎的 "pick who gets the slots" 排序处
功能: 当 v3 模型可用且 v3_enabled=true 时, 热线程候选按"模型分数"重排
      (而非纯 CPU%), 让收益高的线程优先上大核; 模型缺失/关闭时完全回退 v2。
默认关闭 (config/v3.conf: v3_enabled=false), 渐进启用。
"""
import sys, os

FUNC = "/data/adb/modules/sd730-scheduler/common/functions.sh"
V3_CONF_REF = '$CONFIG_DIR/v3.conf'

V3_BLOCK = r'''
    # ---- v3.0: model-score reordering (optional, off by default) ----
    # cand_list/keep_list 每行 "cpu|tid"。开启后按 v3_decision.sh 的模型分数
    # 重排 (无分数线程用 cpu 兜底), 让模型判定收益高的线程优先获得 big 槽位。
    # 模型缺失 / NO_MODEL / 关闭 -> 完全回退原 CPU% 排序。
    local v3_on=0
    if [ -f "$CONFIG_DIR/v3.conf" ]; then
        case "$(grep '^v3_enabled=' "$CONFIG_DIR/v3.conf" 2>/dev/null | cut -d'=' -f2-)" in
            true) v3_on=1 ;;
        esac
    fi
    if [ "$v3_on" = "1" ] && [ -f "$MODDIR/model/mlp_v3_enc.txt" ] && \
       [ -f "$MODDIR/model/mlp_v3_scr.txt" ] && [ -x "$MODDIR/bin/v3_decision.sh" ]; then
        local v3_scores
        v3_scores=$("$MODDIR/bin/v3_decision.sh" 2>/dev/null)
        case "$v3_scores" in
            ""|NO_MODEL|NO_STATE|NO_THREADS) ;;
            *)
                local _ll _lk _ltid _lsc _lcpu _rlist=""
                v3_reorder_list() {
                    local _list="$1" _scores="$2" _line _tid _cpu _score
                    _rlist=""
                    while IFS= read -r _line; do
                        [ -z "$_line" ] && continue
                        _cpu=${_line%%|*}; _tid=${_line##*|}
                        _score=$(echo "$_scores" | awk -F'|' -v t="$_tid" '$1==t {print $2; exit}')
                        case "$_score" in ''|*[!0-9.]*) _score=-1 ;; esac
                        printf '%s\n' "${_score}|${_cpu}|${_tid}"
                    done <<V3EOF
$_list
V3EOF
                }
                if [ "$n_keep" -gt 1 ]; then
                    keep_list=$(v3_reorder_list "$keep_list" "$v3_scores" | sort -t'|' -k1,1 -rn | awk -F'|' '{print $2"|"$3}')
                fi
                if [ "$n_cand" -gt 1 ]; then
                    cand_list=$(v3_reorder_list "$cand_list" "$v3_scores" | sort -t'|' -k1,1 -rn | awk -F'|' '{print $2"|"$3}')
                fi
                ;;
        esac
    fi
    # ---- v3 reorder end ----
'''

def patch():
    with open(FUNC, "r") as f:
        content = f.read()

    if "v3_reorder_list" in content:
        print("[!] Already patched v3. Abort.")
        sys.exit(1)

    # 锚点: cand_list 排序 (v2.1 补丁后唯一出现处)
    anchor = """        if [ "$n_cand" -gt 1 ]; then
            cand_list=$(printf '%s' "$cand_list" | sort -t'|' -k1,1 -rn)
        fi"""
    if anchor not in content:
        # 尝试缩进变体
        anchor2 = """            cand_list=$(printf '%s' "$cand_list" | sort -t'|' -k1,1 -rn)"""
        if anchor2 in content:
            anchor = anchor2
        else:
            print("[!] v3 anchor not found. Abort.")
            sys.exit(1)

    content = content.replace(anchor, anchor + V3_BLOCK, 1)

    tmp = FUNC + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, FUNC)
    print("[+] functions.sh patched with v3 thread-reorder (v3.0)")
    print(f"[+] Lines: {len(content.splitlines())}")

if __name__ == "__main__":
    patch()
