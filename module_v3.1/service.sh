#!/system/bin/sh
MODDIR=${0%/*}

# NN v3.1 (merge fix): 最先拉起数据采集器, 再初始化其它逻辑。
# ensure_collector.sh 不依赖 functions.sh, 即使后面 source 或自钉核卡住,
# 采集器也已经先起来了 (幂等: 已运行则跳过; post-fs-data 已拉起则不重复)。
sh "$MODDIR/bin/ensure_collector.sh" service

. $MODDIR/common/functions.sh

# Keep the module's OWN work (dumpsys, /proc sampling, learning math) off the
# big cluster: self-pin the daemon to LITTLE cores before doing anything else.
# Everything forked from this shell inherits the mask.
self_pin_little
# Log the affinity binding environment once (taskset/busybox paths, topology)
aff_env_log

# GPU watchdog (write-first, v1.5.4): while ultra is active it REWRITES the
# whole lock stack (devfreq min/max, governor, pwrlevels, force_clk) every
# lock_write_interval - even when nothing drifted - and only then reads back
# for verification, so a thermal clamp is corrected by the next write instead
# of discovered by the next read. Between writes it lets the floor breathe
# down to ultra_floor_hz after sustained quiet (no hot threads); the ceiling
# never moves. In non-ultra modes it re-asserts the per-app GPU tier band on
# drift (1s). Forked AFTER self_pin_little, so it inherits the LITTLE-cluster
# mask. The pid file is managed HERE: $$ inside the forked subshell is this
# shell's pid (POSIX), so the watchdog cannot record its own pid - $! can.
[ -f "$GPU_WD_PID" ] && kill "$(cat "$GPU_WD_PID" 2>/dev/null)" 2>/dev/null
gpu_lock_watchdog &
echo $! > "$GPU_WD_PID" 2>/dev/null

sleep 15

# Init Scene state file once /sdcard (FUSE) is up. Runs in a background
# subshell so the scheduler loop is not blocked waiting for storage.
(
    i=0
    while [ ! -d /sdcard/Android ] && [ "$i" -lt 60 ]; do sleep 5; i=$((i+1)); done
    mkdir -p /sdcard/Android/sd730-scheduler 2>/dev/null
    [ ! -f /sdcard/Android/sd730-scheduler/cur_powermode.txt ] && \
        echo "balance" > /sdcard/Android/sd730-scheduler/cur_powermode.txt 2>/dev/null
) &

NN_WD=0              # NN v3.1: collector 守护计数器
AUTO_CHK=0           # NN v3.1.1: 自动训练检查计数器 (每 300 轮 x 3s = 15 分钟)
AUTO_TRAIN_LOG="/data/local/tmp/sd730-nn-auto-train.log"
PREV_APP=""
PREV2_APP=""          # app before PREV_APP: second-order prediction context
PREDICTED_APP=""
SCENE_PREV=""
SCENE_HOLD_UNTIL=0

# 自动训练日志滚动 (v3.1.1): 超 256KB 保留末 200 行, 与 functions.sh log_msg 一致
rotate_auto_log() {
    local size=$(wc -c < "$AUTO_TRAIN_LOG" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt 262144 ] 2>/dev/null; then
        tail -n 200 "$AUTO_TRAIN_LOG" > "$AUTO_TRAIN_LOG.tmp" 2>/dev/null && mv "$AUTO_TRAIN_LOG.tmp" "$AUTO_TRAIN_LOG" 2>/dev/null
    fi
}

# ==================== NN 自动训练 (v3.2) ====================
# 神经网络(线程级)模型默认开启自动训练 (config/v3.conf v3_auto_train=true)。
# 触发条件 (每天最多一次, 在训练窗口内):
#   - 窗口: nn_train_start_hour:00 ~ nn_train_end_hour:00 (默认 1:00-4:00)
#   - 当天未训练 (状态文件 data/collector/.auto_train)
#   - 样本门槛交给训练脚本自身把关 (train_thread*.py, >=300)
#   - 训练成功才写状态文件; 失败当天窗口内会重试
# 训练在后台子 shell 运行, 不阻塞主循环; 输出追加到 $AUTO_TRAIN_LOG
# v3.2 变更: 移除 V2 自动训练 (nn_auto_train), 仅保留神经网络模型自动训练
nn_auto_train_check() {
    local today hour shour ehour inw auto3
    today=$(date +%Y%m%d)
    hour=$(date +%H)
    rotate_auto_log   # 滚动检查 (每次检查触发前) (v3.1.1)
    shour=$(grep '^nn_train_start_hour=' "$NN_CONF" 2>/dev/null | cut -d= -f2-)
    case "$shour" in ''|*[!0-9]*) shour=1 ;; esac
    ehour=$(grep '^nn_train_end_hour=' "$NN_CONF" 2>/dev/null | cut -d= -f2-)
    case "$ehour" in ''|*[!0-9]*) ehour=4 ;; esac
    # 神经网络模型自动训练开关 (默认 true)
    auto3=$(grep '^v3_auto_train=' "$MODDIR/config/v3.conf" 2>/dev/null | cut -d= -f2-)
    [ "$auto3" != "false" ] && auto3="true"

    # 窗口判断 (支持跨天, 如 23:00-04:00)
    inw=0
    if [ "$shour" -le "$ehour" ]; then
        [ "$hour" -ge "$shour" ] && [ "$hour" -lt "$ehour" ] && inw=1
    else
        { [ "$hour" -ge "$shour" ] || [ "$hour" -lt "$ehour" ]; } && inw=1
    fi
    [ "$inw" = "0" ] && return

    # 防重入: 已有训练在跑则跳过 (pgrep 不会匹配到自身)
    pgrep -f "train_thread" >/dev/null 2>&1 && return

    if [ "$auto3" = "true" ] && [ ! -f "$NN_DATA_DIR/.auto_train" ]; then
        log_msg "[NN] Auto-train triggered (window ${shour}:00-${ehour}:00)"
        (
            echo "===== AUTO-TRAIN $(date '+%F %T') =====" >> "$AUTO_TRAIN_LOG"
            sh "$MODDIR/bin/train.sh" >> "$AUTO_TRAIN_LOG" 2>&1
            if [ $? -eq 0 ]; then
                echo "$today" > "$NN_DATA_DIR/.auto_train" 2>/dev/null
                echo "[AUTO-TRAIN] ok, done for today" >> "$AUTO_TRAIN_LOG"
            else
                echo "[AUTO-TRAIN] failed (rc=$?), retry later today" >> "$AUTO_TRAIN_LOG"
            fi
        ) &
        return
    fi
}

while true; do
    # Clear prediction flag once the VALIDATION window closes (this is longer
    # than the boost window, so the user has time to actually switch apps).
    if [ -n "$PREDICTED_APP" ]; then
        if [ -f "$PREDICTION_ACTIVE" ]; then
            valid_until=$(cut -d'|' -f4 "$PREDICTION_ACTIVE" 2>/dev/null)
            now_ts=$(date +%s)
            case "$valid_until" in ''|*[!0-9]*) valid_until=0 ;; esac
            if [ "$now_ts" -ge "$valid_until" ] 2>/dev/null; then
                PREDICTED_APP=""
            fi
        else
            PREDICTED_APP=""
        fi
    fi

    # Scene override: validated, honors the scene_enabled toggle, HOLD-window
    # aware. Scene's external-scheduler API has NO "auto" value: once Scene is
    # bound it always reports one of its 4 modes, so the old "Scene always
    # wins" rule permanently disabled the per-app mode learning. New rule:
    # Scene's value is the BASE mode; a learned per-app mode may override it
    # (mode_learning.conf: learned_overrides_scene=true), EXCEPT during the
    # hold window (scene_hold_seconds) right after Scene's value actually
    # CHANGED - a fresh manual toggle / per-app binding / automation write is
    # real intent and wins immediately. Same-value re-asserts do not refresh
    # the window, so Scene's watchdogs cannot starve the learner.
    SCENE_MODE=""
    SCENE_HOLD=0
    scene_on=$(read_cfg "$MODDIR/config/scene.conf" "scene_enabled" "true")
    if [ "$scene_on" = "true" ]; then
        raw_scene=$(cat $MODDIR/config/scene_mode 2>/dev/null | tr -d '[:space:]')
        case "$raw_scene" in
            powersave|balanced|performance|ultra)
                SCENE_MODE="$raw_scene"
                if [ "$SCENE_MODE" != "$SCENE_PREV" ]; then
                    hold_secs=$(read_cfg "$MODDIR/config/scene.conf" "scene_hold_seconds" "12")
                    case "$hold_secs" in ''|*[!0-9]*) hold_secs=12 ;; esac
                    SCENE_HOLD_UNTIL=$(( $(date +%s) + hold_secs ))
                    SCENE_PREV="$SCENE_MODE"
                fi
                [ "$(date +%s)" -lt "$SCENE_HOLD_UNTIL" ] 2>/dev/null && SCENE_HOLD=1
                ;;
            # "auto" or garbage -> no Scene constraint
        esac
    fi

    # One dumpsys per cycle; reused by mode resolution, application and learning
    CURR_APP=$(get_foreground_app)

    # Mode-learning auto-apply. Suppressed while a fresh Scene action is in
    # its hold window (or entirely when learned_overrides_scene=false and
    # Scene reports a valid mode). The state file is written ONLY here and is
    # never fed back into record_mode_switch, so the module cannot mistake
    # its own choice for user intent.
    LEARNED_MODE=""
    LEARN_OK=1
    if [ "$SCENE_HOLD" = "1" ]; then
        LEARN_OK=0
    elif [ -n "$SCENE_MODE" ] && \
         [ "$(read_cfg "$MODE_LEARN_CONF" "learned_overrides_scene" "true")" != "true" ]; then
        LEARN_OK=0
    fi
    if [ "$LEARN_OK" = "0" ]; then
        rm -f "$MODE_LEARN_STATE" 2>/dev/null
    elif [ -n "$CURR_APP" ] && [ "$(read_cfg "$MODE_LEARN_CONF" "auto_apply" "true")" = "true" ]; then
        # Re-decide on app switch OR when the state file was lost (e.g. a
        # Scene hold window ended while staying in the same app).
        if [ "$CURR_APP" != "$PREV_APP" ] || [ ! -f "$MODE_LEARN_STATE" ]; then
            decision=$(mode_learn_decide "$CURR_APP")
            if [ -n "$decision" ]; then
                d_mode=$(echo "$decision" | cut -d'|' -f1)
                d_share=$(echo "$decision" | cut -d'|' -f2)
                d_total=$(echo "$decision" | cut -d'|' -f3)
                old=$(cut -d'|' -f2 "$MODE_LEARN_STATE" 2>/dev/null)
                echo "${CURR_APP}|${d_mode}|$(date +%s)" > "$MODE_LEARN_STATE" 2>/dev/null
                [ "$old" != "$d_mode" ] && \
                    log_msg "[MLEARN] Auto-applied $d_mode for $CURR_APP (${d_share}% of ${d_total} manual switches)"
            else
                rm -f "$MODE_LEARN_STATE" 2>/dev/null
            fi
        fi
        if [ -f "$MODE_LEARN_STATE" ]; then
            l_pkg=$(cut -d'|' -f1 "$MODE_LEARN_STATE" 2>/dev/null)
            l_mode=$(cut -d'|' -f2 "$MODE_LEARN_STATE" 2>/dev/null)
            [ "$l_pkg" = "$CURR_APP" ] && LEARNED_MODE="$l_mode"
        fi
    fi

    # Priority: fresh Scene action > learned per-app mode > Scene base > manual
    if [ "$SCENE_HOLD" = "1" ]; then
        ACTIVE_MODE="$SCENE_MODE"
    elif [ -n "$LEARNED_MODE" ]; then
        ACTIVE_MODE="$LEARNED_MODE"
    elif [ -n "$SCENE_MODE" ]; then
        ACTIVE_MODE="$SCENE_MODE"
    else
        ACTIVE_MODE=$(cat $MODDIR/config/current_mode 2>/dev/null | tr -d '[:space:]')
    fi
    case "$ACTIVE_MODE" in
        powersave|balanced|performance|ultra) ;;
        *) ACTIVE_MODE="balanced" ;;
    esac

    apply_mode "$ACTIVE_MODE" "$CURR_APP"
    run_learning_cycle "$CURR_APP"
    # Per-app GPU tier engine: classify the foreground app from its learned
    # GPU profile and write/maintain its sensible GPU band (non-ultra); in
    # ultra it only publishes the tier for the watchdog's relax hysteresis.
    gpu_app_profile_cycle "$CURR_APP"

    # Watchdog health: every GPU guarantee (write-first lock, tier band and
    # the mode-range fallback assert) dies with the watchdog process, so a
    # dead one is respawned immediately instead of waiting for a reboot.
    WD_PID=$(cat "$GPU_WD_PID" 2>/dev/null)
    case "$WD_PID" in ''|*[!0-9]*) WD_PID="" ;; esac
    if [ -z "$WD_PID" ] || [ ! -d "/proc/$WD_PID" ]; then
        gpu_lock_watchdog &
        echo $! > "$GPU_WD_PID" 2>/dev/null
        log_msg "[GPU][LOCK] watchdog was dead (pid ${WD_PID:-none}), respawned as $!"
    fi

    # Prediction & App Switch Detection
    if [ -n "$CURR_APP" ] && [ "$CURR_APP" != "$PREV_APP" ]; then
        # App just switched
        if [ -n "$PREV_APP" ]; then
            update_prediction_chain "$PREV_APP" "$CURR_APP" "$PREV2_APP"
            # Validate previous prediction if any
            if [ -n "$PREDICTED_APP" ]; then
                validate_prediction "$PREDICTED_APP" "$CURR_APP"
                PREDICTED_APP=""
            fi
        fi
        PREV2_APP="$PREV_APP"
        PREV_APP="$CURR_APP"
    fi

    # Make prediction if no active prediction is pending
    if [ -z "$PREDICTED_APP" ] && [ -n "$CURR_APP" ]; then
        pred_result=$(predict_next_app "$CURR_APP" "$PREV_APP")
        if [ -n "$pred_result" ]; then
            next_app=$(echo "$pred_result" | cut -d'|' -f1)
            conf=$(echo "$pred_result" | cut -d'|' -f2)
            if [ "$conf" -ge "$(read_cfg "$PREDICTION_CONF" "confidence_threshold" "60")" ] 2>/dev/null; then
                if check_prediction_limits && check_false_positive_rate; then
                    apply_prediction_boost "$next_app" "$conf"
                    PREDICTED_APP="$next_app"
                fi
            fi
        fi
    fi

    # NN v3.1: collector 守护 (每 10 轮 x 3s = 30s 检查, 死了自动补拉)
    NN_WD=$((NN_WD + 1))
    if [ $((NN_WD % 10)) -eq 0 ] 2>/dev/null; then
        sh "$MODDIR/bin/ensure_collector.sh" watchdog
    fi

    # NN v3.1.1: 自动训练检查 (每 300 轮 x 3s = 15 分钟; 仅窗口内可能触发)
    AUTO_CHK=$((AUTO_CHK + 1))
    if [ $((AUTO_CHK % 300)) -eq 0 ] 2>/dev/null; then
        nn_auto_train_check
    fi

    sleep 3
done
