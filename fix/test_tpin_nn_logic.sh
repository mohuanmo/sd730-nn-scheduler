#!/bin/bash
# v3.3 TPIN 新增逻辑局部单测 (与 functions.sh 相同代码)
TP_NN_MAX_ADJ=25; TP_NN_ESC="true"; TP_NN_ESC_SCORE=0.50; TP_NN_ESC_SMOOTH=0.70
TP_NN_BALANCE="true"; TP_NN_BALANCE_TOP=4; sm_mode="manage"

# ---- mock nn_infer 输出: name|cpu|score|hot + K= 行 ----
nn_scores="RenderThread|80|0.900|1
main|60|0.550|1
GpuThread|45|0.720|1
AudioThread|20|0.300|0
K=1.100 CAP=1.000 SMOOTH=0.300"

nn_ok=1
nn_top=$(printf '%s\n' "$nn_scores" | grep -v '^K=' | awk -F'|' '{if($3+0>m)m=$3+0} END{printf "%.3f", m+0}')
nn_smooth=$(printf '%s\n' "$nn_scores" | sed -n 's/^K=.* SMOOTH=\([0-9.]*\).*/\1/p' | head -1)
echo "== A. 模型输出解析 =="
echo "  nn_top=$nn_top (期望 0.900)  nn_smooth=$nn_smooth (期望 0.300)"

# ---- B. eff 计算 (权重式) ----
comm="RenderThread"; nns=$(printf '%s\n' "$nn_scores" | awk -F'|' -v n="$comm" '$1==n {print $3; exit}')
nn_adj=$(awk "BEGIN{a=($nns-0.5)*2*$TP_NN_MAX_ADJ; if(a>$TP_NN_MAX_ADJ)a=$TP_NN_MAX_ADJ; if(a< -$TP_NN_MAX_ADJ)a= -$TP_NN_MAX_ADJ; printf \"%d\", a}")
cpu=80; eff=$((cpu + nn_adj))
echo "== B. eff 计算 =="
echo "  $comm: cpu=$cpu score=$nns adj=$nn_adj eff=$eff (期望 adj=+20 eff=100)"
comm="AudioThread"; nns=$(printf '%s\n' "$nn_scores" | awk -F'|' -v n="$comm" '$1==n {print $3; exit}')
nn_adj=$(awk "BEGIN{a=($nns-0.5)*2*$TP_NN_MAX_ADJ; if(a>$TP_NN_MAX_ADJ)a=$TP_NN_MAX_ADJ; if(a< -$TP_NN_MAX_ADJ)a= -$TP_NN_MAX_ADJ; printf \"%d\", a}")
cpu=20; eff=$((cpu + nn_adj))
echo "  $comm: cpu=$cpu score=$nns adj=$nn_adj eff=$eff (期望 adj=-10 eff=10)"

# ---- C. escalate 模型判断 (模型不认可 -> 不上 3) ----
nn_esc_ok=1
if [ "$TP_NN_ESC" = "true" ] && [ "$nn_ok" = 1 ]; then
    nn_esc_ok=0
    [ "$(awk "BEGIN{print ($nn_top >= $TP_NN_ESC_SCORE)?1:0}")" = 1 ] && \
    [ "$(awk "BEGIN{print ($nn_smooth <= $TP_NN_ESC_SMOOTH)?1:0}")" = 1 ] && nn_esc_ok=1
fi
echo "== C. escalate 判定 =="
echo "  nn_esc_ok=$nn_esc_ok (smooth=0.3<=0.7, top=0.9>=0.5 -> 期望 1=允许)"
# 反例: smooth 流畅 (0.9) -> 不允许
nn_smooth=0.900; nn_esc_ok=1
if [ "$TP_NN_ESC" = "true" ] && [ "$nn_ok" = 1 ]; then
    nn_esc_ok=0
    [ "$(awk "BEGIN{print ($nn_top >= $TP_NN_ESC_SCORE)?1:0}")" = 1 ] && \
    [ "$(awk "BEGIN{print ($nn_smooth <= $TP_NN_ESC_SMOOTH)?1:0}")" = 1 ] && nn_esc_ok=1
fi
echo "  smooth=0.9 -> nn_esc_ok=$nn_esc_ok (期望 0=不允许, 流畅时不加名额)"

# ---- D. 小核均衡 least-loaded ----
CORE_LOAD_FILE="/tmp/core_test/.core_load"; echo "70|60|20|30|80|50|90|40" > "$CORE_LOAD_FILE"
bl_pool="1001|0.900|80
1002|0.720|45
1003|0.550|60
1004|0.300|20
1005|0.100|10"
big_tids=" 1001 "   # 1001 已进大核, 从均衡池排除
TP_NN_BALANCE="true"
little_plan=""
if [ "$TP_NN_BALANCE" = "true" ] && [ "$nn_ok" = 1 ] && [ "$sm_mode" = "manage" ] && [ -n "$bl_pool" ]; then
    pl_cands=""; pl_line=""; pl_tid=""; pl_s=""; pl_c=""
    for pl_line in $bl_pool; do
        pl_tid=${pl_line%%|*}; pl_rest=${pl_line#*|}; pl_s=${pl_rest%%|*}; pl_c=${pl_rest##*|}
        case "$big_tids" in
            *" $pl_tid "*) ;;
            *) pl_cands="${pl_cands}${pl_s}|${pl_tid}
" ;;
        esac
    done
    pl_cands=$(printf '%b' "$pl_cands" | sort -t'|' -k1,1 -rn | head -n "$TP_NN_BALANCE_TOP")
    if [ -n "$pl_cands" ]; then
        cl0=0; cl1=0; cl2=0; cl3=0; cl4=0; cl5=0; cl6=0; cl7=0
        IFS='|' read -r cl0 cl1 cl2 cl3 cl4 cl5 cl6 cl7 < "$CORE_LOAD_FILE" 2>/dev/null
        l0=$cl0; l1=$cl1; l2=$cl2; l3=$cl3; l4=$cl4; l5=$cl5
        pl2=""; pl_best_v=0; pl_best_n=0; pl_maskhex=""; pl_tid2=""; pl_s2=""
        for pl2 in $pl_cands; do
            pl_s2=${pl2%%|*}; pl_tid2=${pl2##*|}
            pl_best_v=$l0; pl_best_n=0
            [ "$l1" -lt "$pl_best_v" ] && { pl_best_v=$l1; pl_best_n=1; }
            [ "$l2" -lt "$pl_best_v" ] && { pl_best_v=$l2; pl_best_n=2; }
            [ "$l3" -lt "$pl_best_v" ] && { pl_best_v=$l3; pl_best_n=3; }
            [ "$l4" -lt "$pl_best_v" ] && { pl_best_v=$l4; pl_best_n=4; }
            [ "$l5" -lt "$pl_best_v" ] && { pl_best_v=$l5; pl_best_n=5; }
            pl_maskhex=$(printf '%x' $((1 << pl_best_n)))
            little_plan="${little_plan}${pl_tid2}|${pl_maskhex}
"
            case "$pl_best_n" in
                0) l0=$((l0 + 20)) ;; 1) l1=$((l1 + 20)) ;;
                2) l2=$((l2 + 20)) ;; 3) l3=$((l3 + 20)) ;;
                4) l4=$((l4 + 20)) ;; 5) l5=$((l5 + 20)) ;;
            esac
        done
    fi
fi
echo "== D. 小核均衡计划 (核负载 70|60|20|30|80|50, 期望最闲的 cpu2 最先被占用) =="
printf '%b' "$little_plan" | while IFS='|' read -r t m; do echo "  tid=$t -> mask=0x$m"; done
echo "  (期望: 1002(0.72) -> 2号核(20) mask=0x4; 1003(0.55) -> 3号核(30) mask=0x8; 1004(0.3) -> 2号核(40) mask=0x4; 1005(0.1) -> 2号核(60)? 实际看贪心)"
