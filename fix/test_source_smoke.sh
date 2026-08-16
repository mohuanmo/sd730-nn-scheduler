#!/bin/bash
set -u 2>/dev/null || true
. /workspace/调度/common/functions.sh
echo "== source 完成, 函数数: $(declare -F | wc -l) =="

TMPCFG=$(mktemp -d)
cat > "$TMPCFG/thread_pin.conf" <<'C'
thread_pin_enabled=true
base_pinned_threads=2
max_pinned_threads=3
big_mask=c0
self_mask=3f
nn_manage=true
nn_max_adjust=30
nn_esc_enabled=true
nn_esc_score=0.60
nn_esc_smooth=0.75
nn_balance_little=true
nn_balance_top=6
C
TPIN_CONF="$TMPCFG/thread_pin.conf"
tpin_load_conf
echo "== tpin_load_conf 解析 (配置文件) =="
echo "  TP_NN_MANAGE=$TP_NN_MANAGE | TP_NN_MAX_ADJ=$TP_NN_MAX_ADJ (期望30) | TP_NN_ESC_SCORE=$TP_NN_ESC_SCORE (期望0.60)"
echo "  TP_NN_ESC_SMOOTH=$TP_NN_ESC_SMOOTH (期望0.75) | TP_NN_BALANCE_TOP=$TP_NN_BALANCE_TOP (期望6)"
echo "  TP_BIG_MASK=$TP_BIG_MASK | TP_SELF_MASK=$TP_SELF_MASK"

rm -rf "$TMPCFG"; mkdir -p "$TMPCFG"; TPIN_CONF="$TMPCFG/thread_pin.conf"
tpin_load_conf
echo "== 配置缺失默认值 =="
echo "  TP_NN_MANAGE=$TP_NN_MANAGE | TP_NN_MAX_ADJ=$TP_NN_MAX_ADJ | TP_NN_ESC_SCORE=$TP_NN_ESC_SCORE | TP_NN_ESC_SMOOTH=$TP_NN_ESC_SMOOTH | TP_NN_BALANCE_TOP=$TP_NN_BALANCE_TOP"

echo "== 关键函数存在性 =="
for f in apply_app_affinity_smart apply_app_affinity aff_bind_tid cold_thread_mask get_temperature get_app_pids tpin_load_conf; do
    type $f >/dev/null 2>&1 && echo "  ✓ $f" || echo "  ✗ $f 缺失"
done
rm -rf "$TMPCFG"
