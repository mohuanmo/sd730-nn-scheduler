#!/system/bin/sh
################################################################################
# nn_infer_v3.sh - v3.0 双模块推理 (场景编码器 + 线程打分器)
#
# 输入:
#   .coll_state           聚合状态 6 字段 (pkg|jiffies|ts|threads|mem|cpu)
#   .threads_snapshot     线程快照 (每行: name|cpu%|21维线程特征), 由 collector 采样
#   model/mlp_v3_enc.txt  场景编码器权重 (33->10: W1,b1,Wk,bk,Ws,bs) (v3.3)
#   model/mlp_v3_scr.txt  线程打分器权重 (31->8->1: W1,b1,W2,b2)
#   (兼容旧 25 维模型: 动态识别 W1 行数)
#
# 输出:
#   每线程: name|cpu_pct|score|hot
#   末尾:   K=<k> CAP=<cap>
#   模型缺失: NO_MODEL
################################################################################

MODDIR="/data/adb/modules/sd730-scheduler"
ENC="$MODDIR/model/mlp_v3_enc.txt"
SCR="$MODDIR/model/mlp_v3_scr.txt"
COLL_STATE="$MODDIR/data/collector/.coll_state"
THREADS_FILE="$MODDIR/data/collector/.threads_snapshot"
FG_DUR_FILE="$MODDIR/data/collector/.fg_duration"

[ -f "$ENC" ] && [ -f "$SCR" ] || { echo "NO_MODEL"; exit 0; }
[ -f "$COLL_STATE" ] || { echo "NO_STATE"; exit 0; }

# ---- 聚合状态 (与 nn_infer.sh 相同的读取) ----
CPU=$(cut -d'|' -f6 "$COLL_STATE" 2>/dev/null)
case "$CPU" in ''|*[!0-9]*) CPU=0 ;; esac
[ "$CPU" -gt 100 ] && CPU=100
THREADS_CNT=$(cut -d'|' -f4 "$COLL_STATE" 2>/dev/null)
case "$THREADS_CNT" in ''|*[!0-9]*) THREADS_CNT=0 ;; esac
MEM=$(cut -d'|' -f5 "$COLL_STATE" 2>/dev/null)
case "$MEM" in ''|*[!0-9]*) MEM=0 ;; esac
PKG=$(cut -d'|' -f1 "$COLL_STATE" 2>/dev/null)

GPU=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d '% \r\t')
case "$GPU" in ''|*[!0-9]*) GPU=0 ;; esac
[ "$GPU" -gt 100 ] && GPU=100

# v3.1.1: 只统计真正的温度传感器, 过滤 lmh-dcvs/ibat/vbat/bcl/soc/step/lowf;
# 旧实现全 zone 取最大/1000 会把 lmh-dcvs 的 75000 误采成 75°C, 污染推理特征。
MAX_TEMP=0
for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$zone" ] || continue
    TYPE=$(cat "${zone%/temp}/type" 2>/dev/null)
    case "$TYPE" in
        *-tz|*-usr|*therm*|battery|bms) ;;
        *) continue ;;
    esac
    T=$(cat "$zone" 2>/dev/null)
    case "$T" in ''|*[!0-9]*) continue ;; esac
    [ "$T" -le 0 ] && continue
    C=0
    if [ "$T" -ge 10000 ] && [ "$T" -le 150000 ]; then
        C=$((T / 1000))
    elif [ "$T" -ge 100 ] && [ "$T" -le 1500 ]; then
        C=$(( (T + 5) / 10 ))
    elif [ "$T" -ge 10 ] && [ "$T" -le 150 ]; then
        C=$T
    fi
    [ "$C" -ge 10 ] && [ "$C" -le 90 ] && [ "$C" -gt "$MAX_TEMP" ] && MAX_TEMP=$C
done
TEMP=$MAX_TEMP

BATT=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "50")
case "$BATT" in ''|*[!0-9]*) BATT=50 ;; esac

CHG=0
case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
    Charging|Charging*) CHG=1 ;;
esac

SCREEN=1
FG_APP=$(dumpsys activity activities 2>/dev/null | grep -E "mResumedActivity" | head -1 | sed -n 's/.*{[^}]* \([^ ]*\)\/.*/\1/p')
case "$FG_APP" in ""|"android"*|"com.android.systemui"*) SCREEN=0 ;; esac

HOUR=$(date +%H); HOUR=${HOUR#0}
case "$HOUR" in ''|*[!0-9]*) HOUR=12 ;; esac

FG_DUR=0
[ -f "$FG_DUR_FILE" ] && FG_DUR=$(cat "$FG_DUR_FILE" 2>/dev/null)
case "$FG_DUR" in ''|*[!0-9]*) FG_DUR=0 ;; esac

# v3.3: 每核使用率 (.core_load = c0|c1|...|c7, 采集端每 5s 更新)
CORE_STR="0|0|0|0|0|0|0|0"
CORE_LOAD_F="$MODDIR/data/collector/.core_load"
if [ -f "$CORE_LOAD_F" ]; then
    CORE_STR=$(cat "$CORE_LOAD_F" 2>/dev/null)
    case "$CORE_STR" in ''|*[!0-9|]*) CORE_STR="0|0|0|0|0|0|0|0" ;; esac
fi

# 帧率反馈特征: .frame_stats = 帧数|平均帧时间ms|方差ms2|0帧比例 (v3.1)
SMOOTH=0.0
FRAME_STATS="$MODDIR/data/collector/.frame_stats"
if [ -f "$FRAME_STATS" ]; then
    local_fs_fn=$(cut -d'|' -f1 "$FRAME_STATS" 2>/dev/null)
    local_fs_avg=$(cut -d'|' -f2 "$FRAME_STATS" 2>/dev/null)
    local_fs_var=$(cut -d'|' -f3 "$FRAME_STATS" 2>/dev/null)
    local_fs_zero=$(cut -d'|' -f4 "$FRAME_STATS" 2>/dev/null)
    case "$local_fs_fn" in ''|*[!0-9]*) local_fs_fn=0 ;; esac
    case "$local_fs_avg" in ''|*[!0-9.]*) local_fs_avg=0 ;; esac
    case "$local_fs_var" in ''|*[!0-9.]*) local_fs_var=0 ;; esac
    case "$local_fs_zero" in ''|*[!0-9.]*) local_fs_zero=1 ;; esac
    # 帧率有效且未跑满: smooth = 1 - clamp(var/25, 0, 1)
    if [ "$local_fs_fn" -ge 10 ] 2>/dev/null && \
       [ "$(awk "BEGIN {print ($local_fs_zero <= 0.3) ? 1 : 0}" 2>/dev/null)" = "1" ] && \
       [ "$(awk "BEGIN {print ($local_fs_avg > 17.5) ? 1 : 0}" 2>/dev/null)" = "1" ]; then
        SMOOTH=$(awk "BEGIN {s=1-$local_fs_var/25; if(s<0)s=0; if(s>1)s=1; print s}" 2>/dev/null)
    else
        SMOOTH=1.0   # 跑满或数据无效: 视为流畅(不激励绑核)
    fi
    case "$SMOOTH" in ''|*[!0-9.]*) SMOOTH=0.0 ;; esac
fi

# ---- 应用类别 (6 类) ----
app_category() {
    case "$1" in
        *tmgp*|*miHoYo*|*netease*|*game*|*honor*|*sgame*) echo 0 ;;
        *aweme*|*douyin*|*bilibili*|*youtube*|*video*|*huoshan*) echo 1 ;;
        *tencent.mm*|*weibo*|*qq*|*telegram*|*whatsapp*|*dingtalk*) echo 2 ;;
        *browser*|*chrome*|*firefox*|*quark*) echo 3 ;;
        *autonavi*|*baidu.map*|*maps*|*navigation*) echo 4 ;;
        *) echo 5 ;;
    esac
}
CAT=$(app_category "$PKG")

# ---- 包名 hash 8 位 (h*31+c, 与训练端 python 一致) ----
pkg_hash() {
    local s="$1" h=0 byte bits="" i=0
    for byte in $(printf '%s' "$s" | od -An -tu1 2>/dev/null); do
        case "$byte" in ''|*[!0-9]*) continue ;; esac
        h=$(( (h * 31 + byte) & 0xFFFFFFFF ))
    done
    while [ $i -lt 8 ]; do
        bits="$bits $(( (h >> i) & 1 ))"
        i=$((i+1))
    done
    echo "$bits"
}
HASH=$(pkg_hash "$PKG")

# ---- 33 维场景特征 (逗号分隔) ----
# 1-10 聚合: cpu,gpu,temp,batt,chg,screen,threads,mem,hour,fgdur
# 11   smooth(流畅度: 1=流畅/跑满, 0=卡顿) (v3.1)
# 12-19 8 核使用率 c0..c7 (/100) (v3.3)
# 20-25 类别 onehot, 26-33 包名 hash
FEAT_ALL=$(awk -v cpu="$CPU" -v gpu="$GPU" -v temp="$TEMP" -v batt="$BATT" \
    -v chg="$CHG" -v screen="$SCREEN" -v th="$THREADS_CNT" -v mem="$MEM" \
    -v hour="$HOUR" -v fgdur="$FG_DUR" -v smooth="$SMOOTH" -v cat="$CAT" -v hash="$HASH" -v core="$CORE_STR" \
'BEGIN {
    f[1]=cpu/100; f[2]=gpu/100; f[3]=temp/100; f[4]=batt/100; f[5]=chg
    f[6]=screen; f[7]=th/100; f[8]=mem/4096; f[9]=hour/24; f[10]=(fgdur>300)?1.0:fgdur/300
    f[11]=smooth
    split(core, cc, "|")
    for(i=1;i<=8;i++) f[11+i]=(cc[i]+0)/100
    for(i=1;i<=6;i++) f[19+i]=(cat==i-1)?1:0
    split(hash, hh, " ")
    for(i=1;i<=8;i++) f[25+i]=hh[i]+0
    s=""
    for(i=1;i<=33;i++){ if(i>1)s=s","; s=s sprintf("%.6f", f[i]) }
    print s
}')

# ---- awk 双模块前向 ----
awk -v FEAT_ALL="$FEAT_ALL" -v ENC="$ENC" -v SCR="$SCR" -v THREADS="$THREADS_FILE" '
BEGIN {
    # ---- 场景编码器 (25/33->10, v3.3 动态识别输入维度) ----
    n_in=0
    while ((getline l<ENC)>0) {
        n_in++
        split(l,r); for(j=1;j<=10;j++) W1[n_in,j]=r[j]
        if (n_in >= 33) break
    }
    if (n_in < 25) { print "MODEL_BROKEN"; exit }
    if((getline l<ENC)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=10;j++) b1[j]=r[j]
    for(i=1;i<=10;i++){ if((getline l<ENC)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=2;j++) Wk[i,j]=r[j] }
    if((getline l<ENC)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=2;j++) bk[j]=r[j]
    for(i=1;i<=10;i++){ if((getline l<ENC)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=10;j++) Ws[i,j]=r[j] }
    if((getline l<ENC)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=10;j++) bs[j]=r[j]
    close(ENC)
    split(FEAT_ALL, fa, ",")
    for(i=1;i<=n_in;i++) x[i]=fa[i]+0
    for(j=1;j<=10;j++){ z=b1[j]; for(i=1;i<=n_in;i++) z+=x[i]*W1[i,j]; h[j]=(z>0)?z:0 }
    o1=bk[1]; o2=bk[2]
    for(j=1;j<=10;j++){ o1+=h[j]*Wk[j,1]; o2+=h[j]*Wk[j,2] }
    k=0.5+1.5/(1+exp(-o1)); cap=0.5+1.0/(1+exp(-o2))
    for(j=1;j<=10;j++){ zs=bs[j]; for(i=1;i<=10;i++) zs+=h[i]*Ws[i,j]; s[j]=zs }

    # ---- 线程打分器 (10+21->8->1) ----
    for(i=1;i<=31;i++){ if((getline l<SCR)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=8;j++) TW1[i,j]=r[j] }
    if((getline l<SCR)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=8;j++) tb1[j]=r[j]
    for(i=1;i<=8;i++){ if((getline l<SCR)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=1;j++) TW2[i,j]=r[j] }
    if((getline l<SCR)<=0){print "MODEL_BROKEN";exit}; split(l,r); for(j=1;j<=1;j++) tb2[j]=r[j]
    close(SCR)

    while ((getline tl < THREADS) > 0) {
        split(tl, tv, "|")
        tname=tv[1]; t_cpu=tv[2]+0
        for(i=1;i<=21;i++) tx[i]=tv[2+i]+0
        for(j=1;j<=8;j++){ z=tb1[j]; for(i=1;i<=10;i++) z+=s[i]*TW1[i,j]; for(i=1;i<=21;i++) z+=tx[i]*TW1[10+i,j]; th[j]=(z>0)?z:0 }
        oz=tb2[1]; for(j=1;j<=8;j++) oz+=th[j]*TW2[j,1]
        score=1/(1+exp(-oz))
        hot=(t_cpu>=25)?1:0
        printf "%s|%d|%.3f|%d\n", tname, t_cpu, score, hot
    }
    close(THREADS)
    printf "K=%.3f CAP=%.3f SMOOTH=%.3f\n", k, cap, f[11]
}'
