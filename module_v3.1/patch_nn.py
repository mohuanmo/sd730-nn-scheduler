#!/data/data/com.termux/files/usr/bin/python3
"""
SD730 Neural Scheduler v2.1 - Patch functions.sh
Inserts:
  1. NN paths at top
  2. k + cap_ratio reading in apply_app_affinity_smart()
  3. Dynamic elastic budget adjustment
  4. Warmup boost in cold_thread_mask()
  5. Dynamic thresholds in cold_thread_mask()
"""

import sys
import os

FUNC = "/data/adb/modules/sd730-scheduler/common/functions.sh"

NN_PATHS = """\n# Neural Scheduler paths (v2.1)\nNN_CONF="$CONFIG_DIR/nn.conf"\nNN_MODEL="$MODDIR/model/mlp_weights.txt"\nNN_INFER="$MODDIR/bin/nn_infer.sh"\nNN_DATA_DIR="$MODDIR/data/collector"\nNN_K=1.0\nNN_CAP=1.0\n"""

# 在 apply_app_affinity_smart() 开头插入 k + cap_ratio 读取
NN_K_READ = """\n    # ---- NN aggressiveness + elastic budget (v2.1) ----\n    NN_K=1.0\n    NN_CAP=1.0\n    local nn_enabled="true" nn_alpha=0.0 nn_temp_limit=70\n    local nn_warmup_sec=3 nn_warmup_boost=0.3\n    if [ -f "$NN_CONF" ]; then\n        nn_enabled=$(grep "^nn_enabled=" "$NN_CONF" 2>/dev/null | cut -d'=' -f2-)\n        nn_alpha=$(grep "^nn_alpha=" "$NN_CONF" 2>/dev/null | cut -d'=' -f2-)\n        nn_temp_limit=$(grep "^nn_temp_limit=" "$NN_CONF" 2>/dev/null | cut -d'=' -f2-)\n        nn_warmup_sec=$(grep "^nn_warmup_seconds=" "$NN_CONF" 2>/dev/null | cut -d'=' -f2-)\n        nn_warmup_boost=$(grep "^nn_warmup_k_boost=" "$NN_CONF" 2>/dev/null | cut -d'=' -f2-)\n        case "$nn_alpha" in ''|*[!0-9.]*) nn_alpha=0.0 ;; esac\n        case "$nn_temp_limit" in ''|*[!0-9]*) nn_temp_limit=70 ;; esac\n        case "$nn_warmup_sec" in ''|*[!0-9]*) nn_warmup_sec=3 ;; esac\n        case "$nn_warmup_boost" in ''|*[!0-9.]*) nn_warmup_boost=0.3 ;; esac\n    fi\n    local temp_now=$(get_temperature 2>/dev/null || echo 0)\n    if [ "$temp_now" -gt "$nn_temp_limit" ] 2>/dev/null; then\n        nn_alpha=0.0\n    fi\n    if [ "$nn_enabled" = "true" ] && \\\n       [ "$(awk "BEGIN {print ($nn_alpha > 0) ? 1 : 0}")" -eq 1 ] && \\\n       [ -x "$NN_INFER" ]; then\n        local nn_out=$("$NN_INFER" 2>/dev/null)\n        if [ -n "$nn_out" ]; then\n            local k_raw cap_raw\n            read k_raw cap_raw <<< "$nn_out"\n            case "$k_raw" in ''|*[!0-9.]*) k_raw=1.0 ;; esac\n            case "$cap_raw" in ''|*[!0-9.]*) cap_raw=1.0 ;; esac\n            NN_K=$(awk "BEGIN {print ($k_raw < 0.5) ? 0.5 : ($k_raw > 2.0) ? 2.0 : $k_raw}")\n            NN_CAP=$(awk "BEGIN {print ($cap_raw < 0.5) ? 0.5 : ($cap_raw > 1.5) ? 1.5 : $cap_raw}")\n            log_msg "[NN] k=$NN_K cap=$NN_CAP alpha=$nn_alpha temp=${temp_now}C"\n        fi\n    fi\n    # ---- NN read end ----\n"""

# 在弹性预算处插入 cap_ratio 调整
CAP_ADJUST = """\n    # ---- NN elastic budget adjustment (v2.1) ----\n    local _tp_base=$TP_BASE_CAP _tp_max=$TP_MAX_CAP\n    if [ "$(awk "BEGIN {print ($NN_CAP != 1.0) ? 1 : 0}")" -eq 1 ]; then\n        _tp_base=$(awk "BEGIN {print int($TP_BASE_CAP * $NN_CAP)}")\n        _tp_max=$(awk "BEGIN {print int($TP_MAX_CAP * $NN_CAP)}")\n        [ "$_tp_base" -lt 1 ] && _tp_base=1\n        [ "$_tp_max" -lt 1 ] && _tp_max=1\n        [ "$_tp_base" -gt 6 ] && _tp_base=6\n        [ "$_tp_max" -gt 6 ] && _tp_max=6\n    fi\n    local cap=$_tp_base\n    [ "$s_expanded" = 1 ] && cap=$_tp_max\n    [ "$cap" -gt "$_tp_max" ] && cap=$_tp_max\n    # ---- NN budget end ----\n\n"""

def patch():
    with open(FUNC, "r") as f:
        content = f.read()

    if "NN_CAP=1.0" in content:
        print("[!] Already patched v2.1. Abort.")
        sys.exit(1)

    # Step 1: NN paths
    moddir_line = 'MODDIR="/data/adb/modules/sd730-scheduler"'
    if moddir_line not in content:
        print("[!] MODDIR not found. Abort.")
        sys.exit(1)
    content = content.replace(moddir_line, moddir_line + NN_PATHS)

    # Step 2: k + cap_ratio in apply_app_affinity_smart()
    anchor = "apply_app_affinity_smart() {\n    local pkg=$1"
    if anchor not in content:
        print("[!] apply_app_affinity_smart() anchor not found. Abort.")
        sys.exit(1)
    content = content.replace(anchor, anchor + NN_K_READ)

    # Step 3: Elastic budget adjustment
    old_budget = """    local cap=$TP_BASE_CAP
    [ "$s_expanded" = 1 ] && cap=$TP_MAX_CAP
    [ "$cap" -gt "$TP_MAX_CAP" ] && cap=$TP_MAX_CAP

"""
    if old_budget not in content:
        print("[!] Budget anchor not found. Abort.")
        sys.exit(1)
    content = content.replace(old_budget, CAP_ADJUST)

    # Step 4: Dynamic thresholds + warmup in cold_thread_mask()
    old_cold = """    if [ "$cpu" -ge "$TP_COLD_FULL" ]; then COLD_MASK=$coarse; return; fi
    local m
    if [ "$cpu" -ge "$TP_COLD_WIDE" ]; then"""

    new_cold = """    # Dynamic thresholds + warmup boost (v2.1)
    local _tp_full=$TP_COLD_FULL _tp_wide=$TP_COLD_WIDE _tp_mid=$TP_COLD_MID
    if [ "$(awk "BEGIN {print ($NN_K != 1.0) ? 1 : 0}")\" -eq 1 ]; then
        _tp_full=$(awk "BEGIN {print int(20 / $NN_K)}")
        _tp_wide=$(awk "BEGIN {print int(8 / $NN_K)}")
        _tp_mid=$(awk "BEGIN {print int(3 / $NN_K)}")
        [ "$_tp_full" -lt 5 ] && _tp_full=5
        [ "$_tp_wide" -lt 2 ] && _tp_wide=2
        [ "$_tp_mid" -lt 1 ] && _tp_mid=1
    fi
    # Warmup boost: app just switched to foreground -> more aggressive
    local _warmup_boost=0
    if [ -f "$NN_DATA_DIR/.fg_duration" ]; then
        local _fg_dur=$(cat "$NN_DATA_DIR/.fg_duration" 2>/dev/null)
        case "$_fg_dur" in ''|*[!0-9]*) _fg_dur=999 ;; esac
        if [ "$_fg_dur" -lt "$nn_warmup_sec" ] 2>/dev/null; then
            _warmup_boost=$(awk "BEGIN {print int($nn_warmup_boost * 100)}")
        fi
    fi
    cpu=$((cpu + _warmup_boost))
    [ "$cpu" -gt 100 ] && cpu=100
    if [ "$cpu" -ge "$_tp_full" ]; then COLD_MASK=$coarse; return; fi
    local m
    if [ "$cpu" -ge "$_tp_wide" ]; then"""

    if old_cold not in content:
        print("[!] cold_thread_mask() anchor not found. Abort.")
        sys.exit(1)
    content = content.replace(old_cold, new_cold)

    # Also update the mid reference
    content = content.replace('    elif [ "$cpu" -ge "$TP_COLD_MID" ]; then',
                                '    elif [ "$cpu" -ge "$_tp_mid" ]; then')

    # 原子写 (v2.1.4): 先写临时文件再替换, 避免主服务读到半写 functions.sh
    tmp = FUNC + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, FUNC)

    print("[+] functions.sh patched successfully (v2.1)")
    print(f"[+] Lines: {len(content.splitlines())}")

if __name__ == "__main__":
    patch()
