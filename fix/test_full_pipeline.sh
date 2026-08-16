#!/bin/bash
# ============================================================================
# 全链路端到端测试 (v3.3.3 发布物): 采集 → 数据落盘 → 训练 → 模型导出
#                                 → 推理打分 → tid 决策 → 绑核掩码输出
# 被测对象: sd730-scheduler-v3.3.3-module.zip (用户实际刷入的包)
# Mock: dumpsys (fake), 前台 app 用真实 /proc 进程模拟
#       (单 argv cmdline=com.test.game + prctl 改名, 兼容 bash read 的 NUL 处理)
# 宿主 6 核: big_mask=0xc0 超拓扑 -> 执行层会 clamp (决策层输出不受影响)
# ============================================================================
ROOT=/workspace/调度
ZIP=$ROOT/sd730-scheduler-v3.3.4-module.zip
SIM=$ROOT/tmp_e2e
MODDIR=$SIM/mod/data/adb/modules/sd730-scheduler
STUB=$SIM/stub
DC=$MODDIR/data/collector

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

rm -rf "$SIM"; mkdir -p "$MODDIR" "$STUB" "$SIM/bin" "$MODDIR/model"
# 模拟 Android: /system/bin/sh 供脚本 shebang 直接执行 (v3_decision.sh 直接调用 nn_infer_v3.sh)
mkdir -p /system/bin 2>/dev/null
[ -e /system/bin/sh ] || ln -s /bin/sh /system/bin/sh 2>/dev/null || true

# ---- 编译模拟 app 进程 (单 argv cmdline + prctl 改名 + 可选高负载) ----
cat > "$SIM/bin/thr.c" <<'EOF'
#include <sys/prctl.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char**argv){
    const char *n = getenv("THR_NAME");
    if (n && *n) prctl(PR_SET_NAME, (unsigned long)n, 0, 0, 0);
    const char *m = getenv("THR_BUSY");
    if (m && *m=='1') { for(;;){ volatile double x=1.0; for(int i=0;i<100000;i++) x=x*1.00000001+i*1e-12; } }
    sleep(600);
    return 0;
}
EOF
cc -O2 -o "$SIM/bin/thr" "$SIM/bin/thr.c" || { echo "✗ cc 编译失败"; exit 1; }
launch_thr() { # name busy(1/0)
    THR_NAME="$1" THR_BUSY="$2" bash -c 'exec -a com.test.game '"$SIM"'/bin/thr' >/dev/null 2>&1 &
    echo $!
}

echo "════════════════════════════════════════════════════════════════"
echo "  全链路测试: 采集 → 训练 → 推理 → 决策 → 绑核掩码"
echo "════════════════════════════════════════════════════════════════"

# ---------------------------------------------------------------- 阶段 1: 部署
echo "════════ [1/7] 部署模块 (v3.3.3 发布物) ════════"
python3 - "$ZIP" "$MODDIR" <<'PY'
import zipfile, sys, os
z = zipfile.ZipFile(sys.argv[1]); dst = sys.argv[2]
for n in z.namelist():
    if n.endswith('/'): continue
    p = os.path.join(dst, n)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p,'wb') as f: f.write(z.read(n))
print("extracted", len(z.namelist()), "entries")
PY
grep -rl "/data/adb/modules/sd730-scheduler" "$MODDIR" 2>/dev/null | while read -r f; do
    sed -i "s|/data/adb/modules/sd730-scheduler|$MODDIR|g" "$f"
done
[ -f "$MODDIR/config/thread_pin.conf" ] && \
  sed -i 's/^tlearn_enabled=true/tlearn_enabled=false/; s/^tcorr_enabled=true/tcorr_enabled=false/; s/^selfmanage_enabled=true/selfmanage_enabled=false/' "$MODDIR/config/thread_pin.conf"
echo "balanced" > "$MODDIR/config/current_mode" 2>/dev/null
chmod +x "$MODDIR"/bin/*.sh "$MODDIR"/system/bin/sd730-scheduler "$MODDIR"/*.py 2>/dev/null
chk "发布物文件齐全" \
   "test -f $MODDIR/bin/collector.sh -a -f $MODDIR/common/functions.sh -a -f $MODDIR/bin/nn_infer_v3.sh -a -f $MODDIR/bin/v3_decision.sh -a -f $MODDIR/train_thread_pure.py"
chk "collector 为修复版 (CPU_PREV + get_core_load 差分)" \
   "grep -q CPU_PREV $MODDIR/bin/collector.sh -a grep -q 'split(\$0,a,\" \")' $MODDIR/bin/collector.sh"
chk "nn_test 期望行数已更新 (expect 56)" "grep -q 'expect 56' $MODDIR/system/bin/sd730-scheduler"

# ---------------------------------------------------------------- 阶段 2: 采集
echo "════════ [2/7] 采集器 collector.sh (mock dumpsys + 真实模拟 app) ════════"
cat > "$STUB/dumpsys" <<'SH'
#!/bin/bash
case "$1" in
  activity)  echo "  mResumedActivity: ActivityRecord{abc123 u0 com.test.game/.MainActivity t100}"; exit 0 ;;
  window)    echo "  mFocusedWindow: Window{abc123 u0 com.test.game/com.test.game.MainActivity}"; exit 0 ;;
  SurfaceFlinger)
    if [ "$2" = "--list" ]; then echo "com.test.game/com.test.game.MainActivity#0"; exit 0; fi
    if [ "$2" = "--latency" ]; then
      echo "SurfaceFlinger --latency"; echo "0"; echo "0"
      i=0; while [ $i -lt 60 ]; do
        echo "$((i*24000000 + (i%5)*2000000)) $((i*24000000 + (i%5)*2000000)) 0"
        i=$((i+1))
      done
      exit 0
    fi ;;
esac
exit 0
SH
chmod +x "$STUB/dumpsys"
export PATH="$STUB:$PATH"

PID_RT=$(launch_thr RenderThread 1)
PID_MAIN=$(launch_thr main 1)
PID_GPU=$(launch_thr GpuThread 1)
PID_AUD=$(launch_thr AudioThread 0)
sleep 2
chk "模拟 app 4 进程存活 + comm 改名" \
   "test -r /proc/$PID_RT/stat -a \"\$(cat /proc/$PID_RT/task/$PID_RT/comm)\" = RenderThread"
chk "cmdline 精确匹配 com.test.game" \
   "test \"\$(head -c 13 /proc/$PID_RT/cmdline)\" = com.test.game"

timeout 16 sh "$MODDIR/bin/collector.sh" >"$SIM/collector.out" 2>&1
kill "$PID_RT" "$PID_MAIN" "$PID_GPU" "$PID_AUD" 2>/dev/null; wait 2>/dev/null

TODAY=$(date +%Y%m%d)
chk "a. .coll_state 恒 6 字段 (修复后)" \
   "test -f $DC/.coll_state -a \"\$(awk -F'|' '{print NF}' $DC/.coll_state)\" = 6"
chk "b. .threads_snapshot 行=name|cpu|21特征 (NF>=23)" \
   "test -s $DC/.threads_snapshot -a \"\$(head -1 $DC/.threads_snapshot | awk -F'|' '{print NF}')\" -ge 23"
chk "c. .frame_stats 有效帧>=10" \
   "test -f $DC/.frame_stats -a \"\$(cut -d'|' -f1 $DC/.frame_stats)\" -ge 10"
chk "d. .core_load 8 字段且非全 0 (核负载差分修复后)" \
   "test -f $DC/.core_load -a \"\$(awk -F'|' '{print NF}' $DC/.core_load)\" = 8 -a \"\$(echo \$(cat $DC/.core_load) | tr -d '0|' | wc -c)\" -gt 0"
chk "e. .raw 13 字段" \
   "test -f $DC/$TODAY.raw -a \"\$(tail -1 $DC/$TODAY.raw | awk -F'|' '{print NF}')\" = 13"
chk "f. .traw 36 字段 (16前缀+12线程+8核负载)" \
   "test -s $DC/$TODAY.traw -a \"\$(tail -1 $DC/$TODAY.traw | awk -F'|' '{print NF}')\" = 36"
chk "g. traw 有真实线程槽位" \
   "grep -qE 'RenderThread|main|GpuThread' $DC/$TODAY.traw"
echo "  --- .coll_state: $(cat $DC/.coll_state)"
echo "  --- .frame_stats: $(cat $DC/.frame_stats) | .core_load: $(cat $DC/.core_load)"
echo "  --- .threads_snapshot: $(head -2 $DC/.threads_snapshot | tr '\n' ';' | cut -c1-90)"
echo "  --- .traw 尾行: $(tail -1 $DC/$TODAY.traw | cut -c1-130)"

# ---------------------------------------------------------------- 阶段 3: 数据完整性
echo "════════ [3/7] traw 数据完整性 (训练端解析视角) ════════"
python3 - "$DC" "$SIM" <<'PY'
import sys
sys.path.insert(0, '/workspace/调度')
import importlib.util
spec = importlib.util.spec_from_file_location("tp", "/workspace/调度/train_thread_pure.py")
tp = importlib.util.module_from_spec(spec); spec.loader.exec_module(tp)
tp.DATA_DIR = sys.argv[1]
s = tp.load_traw()
if not s:
    print("LOAD_FAIL"); sys.exit(1)
s0 = s[0]
n_thr = max(len(x['threads']) for x in s)
n_core_nonzero = max(sum(1 for c in x['core'] if c>0) for x in s)
print(f"  样本数={len(s)} agg={len(s0['agg'])} core=8 最大真实线程={n_thr} 最大非零核负载={n_core_nonzero}")
ok = len(s0['agg'])==10 and n_thr>0 and n_core_nonzero>=2
open(sys.argv[2]+"/loadchk.ok","w").write("OK" if ok else "BAD")
sys.exit(0 if ok else 2)
PY
chk "训练端解析 traw: agg=10 / core=8 非全 0 / 有真实线程" \
   "test -f $SIM/loadchk.ok -a \"\$(cat $SIM/loadchk.ok)\" = OK"

# ---------------------------------------------------------------- 阶段 4: 训练
echo "════════ [4/7] 训练 (train_thread_pure.py --force, 真实 traw) ════════"
TPPY=$SIM/train_thread_pure.py
cp "$MODDIR/train_thread_pure.py" "$TPPY"   # 部署阶段已替换 MODDIR, 不再二次 sed
python3 "$TPPY" --force > "$SIM/train.out" 2>&1
tail -5 "$SIM/train.out"
chk "训练完成并导出模型" \
   "grep -q 'Exported' $SIM/train.out && test -f $MODDIR/model/mlp_v3_enc.txt && test -f $MODDIR/model/mlp_v3_scr.txt"
chk "enc=56 / scr=41 行" \
   "test \$(wc -l < $MODDIR/model/mlp_v3_enc.txt) -eq 56 -a \$(wc -l < $MODDIR/model/mlp_v3_scr.txt) -eq 41"
chk "enc 布局 (33W1+1b1+10Wk+1bk+10Ws+1bs)" \
   "test \"\$(sed -n '1,33p' $MODDIR/model/mlp_v3_enc.txt | awk '{print NF}' | sort -u | tr '\n' ' ')\" = '10 ' -a \"\$(sed -n '35,44p' $MODDIR/model/mlp_v3_enc.txt | awk '{print NF}' | sort -u | tr '\n' ' ')\" = '2 '"
chk "scr 布局 (31W1+1b1+8W2+1b2)" \
   "test \"\$(sed -n '1,31p' $MODDIR/model/mlp_v3_scr.txt | awk '{print NF}' | sort -u | tr '\n' ' ')\" = '8 ' -a \"\$(sed -n '33,40p' $MODDIR/model/mlp_v3_scr.txt | awk '{print NF}' | sort -u | tr '\n' ' ')\" = '1 '"
chk "nn-test 判定 layout OK" \
   "sh $MODDIR/system/bin/sd730-scheduler --nn-test 2>&1 | grep -q 'layout OK'"

# ---------------------------------------------------------------- 阶段 5: 推理
echo "════════ [5/7] 推理打分 (nn_infer_v3.sh) ════════"
SCORES=$(sh "$MODDIR/bin/nn_infer_v3.sh" 2>/dev/null)
printf '%s\n' "$SCORES" > "$SIM/scores.txt"
echo "  --- nn_infer_v3.sh 输出 ---"; cat "$SIM/scores.txt" | sed 's/^/    /'
N_THR=$(grep -v '^K=' "$SIM/scores.txt" | grep -c '|')
chk "输出 >=1 线程打分行" "test $N_THR -ge 1"
chk "含 K= 汇总行" "grep -q '^K=' $SIM/scores.txt"
chk "score∈[0,1] 且 hot∈{0,1}" \
   "awk -F'|' '\$0 !~ /^K=/ {if(\$3<0||\$3>1||(\$4!=0&&\$4!=1)) exit 1}' $SIM/scores.txt"
chk "输出含模拟线程名" \
   "grep -qE 'RenderThread|main|GpuThread' $SIM/scores.txt"

# ---------------------------------------------------------------- 阶段 6: 决策
echo "════════ [6/7] tid 决策 (v3_decision.sh) ════════"
PID_RT=$(launch_thr RenderThread 1); PID_MAIN=$(launch_thr main 1)
PID_GPU=$(launch_thr GpuThread 1);  PID_AUD=$(launch_thr AudioThread 0)
sleep 2
DEC=$(sh "$MODDIR/bin/v3_decision.sh" 2>/dev/null)
printf '%s\n' "$DEC" > "$SIM/dec.txt"
echo "  --- v3_decision.sh 输出 (tid|score|cpu 降序) ---"; cat "$SIM/dec.txt" | sed 's/^/    /'
N_DEC=$(grep -c '|' "$SIM/dec.txt")
chk "输出 >=1 行 tid|score|cpu" "test $N_DEC -ge 1"
chk "按 score 降序" \
   "awk -F'|' '{if(NR>1 && \$2+0>prev) exit 1; prev=\$2+0}' $SIM/dec.txt"
chk "tid 均为数字" \
   "awk -F'|' '{if(\$1 !~ /^[0-9]+$/) exit 1}' $SIM/dec.txt"
chk "关联到模拟 app 的线程" \
   "grep -qE '^($PID_RT|$PID_MAIN|$PID_GPU|$PID_AUD)\|' $SIM/dec.txt"
chk "模型分数正确传递 (score>0)" \
   "awk -F'|' '{if(\$2+0>0) found=1} END{exit !found}' $SIM/dec.txt"

# ---------------------------------------------------------------- 阶段 7: 绑核掩码
echo "════════ [7/7] 绑核掩码输出 ════════"
BIND_LOG=$SIM/bind_log.log; : > "$BIND_LOG"
. "$MODDIR/common/functions.sh"
tpin_load_conf

# 7.1 执行层: 真实 aff_bind_tid + 真实 taskset (0xc0 在 6 核宿主上会 clamp)
aff_bind_tid "$PID_AUD" c0 'EXEC' 2>/dev/null
chk "真实 aff_bind_tid 执行 (ok/clamped)" \
   "test \$AFF_LAST = ok -o \$AFF_LAST = clamped"
echo "    AFF_LAST=$AFF_LAST (宿主 $(nproc) 核)"

# 7.2 决策层: override aff_bind_tid 记录引擎输出的掩码
aff_bind_tid() { echo "BIND|$1|$2|$3" >> "$BIND_LOG"; AFF_LAST=ok; return 0; }
get_app_pids() { echo "$PID_RT $PID_MAIN $PID_GPU $PID_AUD"; }
get_temperature() { echo 40; }
release_all_pins() { :; }; tcorr_release_all() { :; }; tcorr_predict() { :; }
read_tid_mask_hex() { echo ""; }; selfm_get_verdict() { echo ""; }; selfm_set_verdict() { :; }
NOW=$(date +%s)
cat > /data/local/tmp/sd730-tpin.state <<STEOF
PKG|com.test.game|0|0|0
TID|$PID_RT|$PID_RT|0|0|$((NOW-5))|80|3|0|||
TID|$PID_MAIN|$PID_MAIN|0|0|$((NOW-5))|60|3|0|||
TID|$PID_GPU|$PID_GPU|0|0|$((NOW-5))|45|3|0|||
TID|$PID_AUD|$PID_AUD|0|0|$((NOW-5))|5|0|0|||
STEOF
for rnd in 1 2 3; do
    apply_app_affinity_smart "com.test.game" "performance" 2>>"$SIM/aff.err"
    sleep 1
done
echo "  --- bind_log (引擎决策输出的绑核掩码) ---"; cat "$BIND_LOG" | sed 's/^/    /'
chk "产生绑核动作" "test -s $BIND_LOG"
chk "高分线程绑大核掩码 c0 (big_mask)" \
   "grep -q 'BIND|.*|c0|' $BIND_LOG"
chk "存在非大核掩码绑定 (小核侧)" \
   "test \$(grep -cv 'BIND|.*|c0|' $BIND_LOG) -ge 1"
chk "无非法掩码 (全 hex)" \
   "test \$(grep -cE 'BIND\|[0-9]+\|[^0-9a-f]+\|' $BIND_LOG) -eq 0"

# 7.3 掩码规范化单测 (6 核宿主: c0 超拓扑 -> clamp 后仍输出合法 hex)
NM=$(aff_mask_normalize "c0" "UT" 2>/dev/null)
chk "aff_mask_normalize 'c0' 输出合法 hex" \
   "test -n \"\$NM\" -a \"\$(echo \"\$NM\" | grep -cE '^[0-9a-f]+$')\" = 1"
NM2=$(aff_mask_normalize "zz" "UT" 2>/dev/null)
chk "aff_mask_normalize 'zz'(非法) 拒绝" "test -z \"\$NM2\""

# 7.4 模型缺失回退
mv "$MODDIR/model/mlp_v3_enc.txt" "$MODDIR/model/.e"; mv "$MODDIR/model/mlp_v3_scr.txt" "$MODDIR/model/.s"
: > "$BIND_LOG"
for rnd in 1 2; do apply_app_affinity_smart "com.test.game" "performance" 2>/dev/null; sleep 1; done
chk "模型缺失时回退规则绑核 (legacy 仍工作)" "test -s $BIND_LOG"
mv "$MODDIR/model/.e" "$MODDIR/model/mlp_v3_enc.txt"; mv "$MODDIR/model/.s" "$MODDIR/model/mlp_v3_scr.txt"

kill "$PID_RT" "$PID_MAIN" "$PID_GPU" "$PID_AUD" 2>/dev/null; wait 2>/dev/null

echo "════════════════════════════════════════════════════════════════"
echo "  结果: PASS=$PASS  FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
