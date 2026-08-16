#!/bin/bash
# v3.3 端到端模拟环境测试 (final)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
chk() { if $2 >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi }

SIM=/tmp/sim_v33
MODDIR=$SIM/data/adb/modules/sd730-scheduler
rm -rf $SIM; mkdir -p $MODDIR/{config,data/collector,model,bin,common}
BIND_LOG=$SIM/bind_log.log; : > $BIND_LOG

echo "════════ [1/6] 部署模块 ════════"
cp common/functions.sh $MODDIR/common/functions.sh
cp bin/nn_infer_v3.sh $MODDIR/bin/nn_infer_v3.sh
python3 -c "import zipfile; zipfile.ZipFile('/workspace/调度/sd730-scheduler-v3.3-module.zip').extract('config/thread_pin.conf','/tmp/tpin_cfg')"
cp /tmp/tpin_cfg/config/thread_pin.conf $MODDIR/config/thread_pin.conf
sed -i "s|/data/adb/modules/sd730-scheduler|$MODDIR|g" $MODDIR/common/functions.sh $MODDIR/bin/nn_infer_v3.sh
chmod +x $MODDIR/bin/nn_infer_v3.sh $MODDIR/common/functions.sh
sed -i 's/^tlearn_enabled=true/tlearn_enabled=false/; s/^tcorr_enabled=true/tcorr_enabled=false/; s/^selfmanage_enabled=true/selfmanage_enabled=false/' $MODDIR/config/thread_pin.conf
chk "模块部署" "test -f $MODDIR/common/functions.sh -a -f $MODDIR/bin/nn_infer_v3.sh -a -f $MODDIR/config/thread_pin.conf"

echo "════════ [2/6] 训练 33 维模型 ════════"
python3 - "$MODDIR" <<'PY'
import sys, os; sys.path.insert(0, '/workspace/调度')
import train_thread_pure as tp
moddir = sys.argv[1]
tmp = '/tmp/sim_v33/traw'; os.makedirs(tmp, exist_ok=True)
rows = []
for i in range(40):
    core = [70,65,35,30,28,25,50,45]
    t = "RenderThread|80|main|60|GpuThread|45|none|0|none|0|none|0"
    c = "|".join(str(x) for x in core)
    rows.append(f"1700000000{i}|com.tencent.tmgp.sgame|60|70|42|50|0|1|80|1200|14|300|60|33.0|150.0|0.05|{t}|{c}")
for i in range(30):
    core = [45,40,25,22,20,18,35,30]
    t = "RenderThread|70|main|50|none|0|none|0|none|0|none|0"
    c = "|".join(str(x) for x in core)
    rows.append(f"1700001000{i}|tv.danmaku.bilibilihd|40|30|42|50|0|1|40|800|14|300|60|33.3|5.0|0.02|{t}|{c}")
open(f"{tmp}/20260816.traw","w").write("\n".join(rows)+"\n")
tp.DATA_DIR = tmp; tp.ENC_OUT = f'{moddir}/model/mlp_v3_enc.txt'; tp.SCR_OUT = f'{moddir}/model/mlp_v3_scr.txt'
tp.EPOCHS = 6
sys.argv = ["train_thread_pure.py", "--force"]
tp.main()
PY
chk "模型导出 enc56/scr41" "test $(wc -l < $MODDIR/model/mlp_v3_enc.txt) -eq 56 -a $(wc -l < $MODDIR/model/mlp_v3_scr.txt) -eq 41"

echo "════════ [3/6] 推理输入 ════════"
DC=$MODDIR/data/collector
echo "com.tencent.tmgp.sgame|0|0|80|1200|60" > $DC/.coll_state
printf 'RenderThread|80|0.8|1|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0\n' > $DC/.threads_snapshot
printf 'main|60|0.6|0|1|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0\n' >> $DC/.threads_snapshot
printf 'GpuThread|45|0.45|0|0|1|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0|0\n' >> $DC/.threads_snapshot
echo "60|33.0|150.0|0.05" > $DC/.frame_stats
echo "70|65|35|30|28|25|50|45" > $DC/.core_load
echo "300" > $DC/.fg_duration
chk "推理输入 5 文件" "test -f $DC/.coll_state -a -f $DC/.threads_snapshot -a -f $DC/.frame_stats -a -f $DC/.core_load -a -f $DC/.fg_duration"

echo "════════ [4/6] 模拟 app (3 热线程 + 1 空闲线程) ════════"
launch_busy() { python3 -c 'import os,time,ctypes,sys; ctypes.CDLL(None).prctl(15, sys.argv[1].encode(), 0, 0, 0); exec("while True: pass")' "$1" >/dev/null 2>&1 & echo $!; }
PID_RT=$(launch_busy RenderThread); PID_MAIN=$(launch_busy main); PID_GPU=$(launch_busy GpuThread)
sleep 300 & PID_AUD=$!          # 空闲线程 (低负载)
sleep 3
CRT=$(cat /proc/$PID_RT/task/$PID_RT/comm 2>/dev/null)
if [ "$CRT" = "RenderThread" ]; then ok "comm 改名"; else bad "comm 改名 (实际=$CRT)"; fi
chk "4 个模拟线程存活" "test -r /proc/$PID_RT/stat -a -r /proc/$PID_MAIN/stat -a -r /proc/$PID_GPU/stat -a -r /proc/$PID_AUD/stat"
rdstat() { local rest; IFS= read -r rest < /proc/$1/stat; rest=${rest##*)}; set -- $rest; echo "$((${12}+${13}))|${20}"; }
NOW=$(date +%s)
for P in RT MAIN GPU AUD; do
    eval "V=\$(rdstat \$PID_$P)"; eval "${P}_J=\${V%%|*}"; eval "${P}_ST=\${V##*|}"
done
cat > /data/local/tmp/sd730-tpin.state <<STEOF
PKG|com.tencent.tmgp.sgame|0|0|0
TID|$PID_RT|$PID_RT|$RT_ST|$((RT_J-200))|$((NOW-5))|80|3|0|||
TID|$PID_MAIN|$PID_MAIN|$MAIN_ST|$((MAIN_J-200))|$((NOW-5))|60|2|0|||
TID|$PID_GPU|$PID_GPU|$GPU_ST|$((GPU_J-200))|$((NOW-5))|45|1|0|||
TID|$PID_AUD|$PID_AUD|$AUD_ST|$((AUD_J-1))|$((NOW-5))|5|0|0|||
STEOF
chk "TPIN_STATE 预热" "test -s /data/local/tmp/sd730-tpin.state"

echo "════════ [5/6] 真实 apply_app_affinity_smart (4 轮) ════════"
. $MODDIR/common/functions.sh
tpin_load_conf
get_app_pids() { echo "$PID_RT $PID_MAIN $PID_GPU $PID_AUD"; }
get_temperature() { echo 40; }
get_affinity_mask() { echo "c0"; }
cold_thread_mask() { COLD_MASK=3f; }
aff_bind_tid() { echo "BIND|$1|$2|$4" >> $BIND_LOG; return 0; }
release_all_pins() { :; }; tcorr_release_all() { :; }; tcorr_predict() { :; }
read_tid_mask_hex() { echo ""; }; selfm_get_verdict() { echo ""; }; selfm_set_verdict() { :; }
for rnd in 1 2 3 4; do
    apply_app_affinity_smart "com.tencent.tmgp.sgame" "performance" 2>/dev/null
    sleep 2
done
echo "--- bind_log (模型在场) ---"; cat $BIND_LOG
chk "产生绑核动作" "test -s $BIND_LOG"
cp $BIND_LOG $SIM/bind_ok.log

echo "════════ [6/6] 协同验证 ════════"
SCORES=$(sh $MODDIR/bin/nn_infer_v3.sh 2>/dev/null)
echo "--- 模型推理 ---"; echo "$SCORES"
N_THR=$(printf '%s\n' "$SCORES" | grep -v '^K=' | grep -c '|')
chk "推理 >=3 线程" "test $N_THR -ge 3"
chk "推理含 K= 行" "printf '%s\n' '$SCORES' | grep -q '^K='"
BIG_BINDS=$(grep -c "BIND|.*|c0|" $BIND_LOG 2>/dev/null || true)
chk "大核绑定 (c0)" "test $BIG_BINDS -ge 1"
LITTLE_BINDS=$(grep -cE 'BIND\|[0-9]+\|(1|2|4|8|10|20)\|' $BIND_LOG 2>/dev/null || true)
chk "小核均衡绑定 (单核掩码)" "test $LITTLE_BINDS -ge 1"
NONBIG_BINDS=$(grep -cv "BIND|.*|c0|" $BIND_LOG 2>/dev/null || true)
chk "存在非大核绑定 (空闲线程)" "test $NONBIG_BINDS -ge 1"
BAD_BINDS=$(grep -cE 'BIND\|[0-9]+\|[^0-9a-f]\|' $BIND_LOG 2>/dev/null || true)
chk "无非法掩码" "test $BAD_BINDS -eq 0"
# 模型缺失回退
mv $MODDIR/model/mlp_v3_enc.txt $MODDIR/model/.e; mv $MODDIR/model/mlp_v3_scr.txt $MODDIR/model/.s
: > $BIND_LOG
for rnd in 1 2 3; do apply_app_affinity_smart "com.tencent.tmgp.sgame" "performance" 2>/dev/null; sleep 2; done
echo "--- bind_log (模型缺失回退) ---"; cat $BIND_LOG
mv $MODDIR/model/.e $MODDIR/model/mlp_v3_enc.txt; mv $MODDIR/model/.s $MODDIR/model/mlp_v3_scr.txt
chk "模型缺失回退仍绑核" "test -s $BIND_LOG"

kill $PID_RT $PID_MAIN $PID_GPU $PID_AUD 2>/dev/null
rm -f /data/local/tmp/sd730-tpin.state
echo ""
echo "════════ 结果: PASS=$PASS FAIL=$FAIL ════════"
[ $FAIL -eq 0 ] && echo "✅ 端到端协同验证全部通过" || echo "❌ 有 $FAIL 项失败"
