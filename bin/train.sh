#!/system/bin/sh
################################################################################
# train.sh - 神经网络模型训练启动器 (v3.2, 仅线程级模型)
#
# 兼容的 Python 环境 (按优先级):
#   1. PATH 中的 python3 (桌面 / Termux PATH / py2droid wrapper)
#   2. py2droid: /system/usr/bin/python3
#   3. Termux:   /data/data/com.termux/files/usr/bin/python3
#
# 训练引擎自动选择 (v3.2):
#   - 有 numpy  -> train_thread.py      (numpy 加速, 200 epochs)
#   - 无 numpy  -> train_thread_pure.py (纯标准库, 60 epochs, 手机夜间可完成)
#   - 两者都产出相同的 awk 可读模型格式 (mlp_v3_enc.txt + mlp_v3_scr.txt)
#
# v3.2 变更: 移除 V2 场景级模型 (train.py / train_pure.py) 训练入口,
# 本脚本只训练神经网络(线程级)模型; --v3 参数保留兼容 (无实际作用)。
#
# 用法:  sh bin/train.sh                 (训练)
#        sh bin/train.sh --force         (强制: 跳过样本量门槛)
#        sh bin/train.sh --help
################################################################################

SCRIPT_DIR=$(dirname "$0")
TRAIN_THREAD_PY="$SCRIPT_DIR/../train_thread.py"
TRAIN_THREAD_PURE_PY="$SCRIPT_DIR/../train_thread_pure.py"

find_python() {
    # 1) PATH 中的 python3
    _p=$(command -v python3 2>/dev/null)
    [ -n "$_p" ] && [ -x "$_p" ] && { echo "$_p"; return; }
    # 2) py2droid (Magisk 系统级 Python)
    [ -x /system/usr/bin/python3 ] && { echo "/system/usr/bin/python3"; return; }
    # 3) Termux
    [ -x /data/data/com.termux/files/usr/bin/python3 ] && { echo "/data/data/com.termux/files/usr/bin/python3"; return; }
    echo ""
}

PY=$(find_python)
if [ -z "$PY" ]; then
    echo "[TRAIN] ERROR: python3 not found." >&2
    echo "[TRAIN] Install one of:" >&2
    echo "[TRAIN]   - py2droid Magisk module (system-level Python)" >&2
    echo "[TRAIN]   - Termux: pkg install python" >&2
    exit 1
fi

echo "[TRAIN] Using python: $PY"

# --v3 兼容参数 (v3.2: 本脚本只训练线程级模型, --v3 不再需要); 其余参数 (如 --force) 原样透传
ARGS=""
for _a in "$@"; do
    [ "$_a" = "--v3" ] && continue
    ARGS="$ARGS $_a"
done

if "$PY" -c "import numpy" >/dev/null 2>&1; then
    echo "[TRAIN] numpy available -> train_thread.py (numpy, 200 epochs)"
    # shellcheck disable=SC2086: 参数均为 --force 之类的简单 token, 无空格
    exec "$PY" -u "$TRAIN_THREAD_PY" $ARGS
else
    echo "[TRAIN] numpy NOT available -> train_thread_pure.py (纯标准库, 60 epochs)"
    echo "[TRAIN] 纯 Python 版零依赖, 速度约为 numpy 版 1/50, 夜间训练可接受"
    # shellcheck disable=SC2086
    exec "$PY" -u "$TRAIN_THREAD_PURE_PY" $ARGS
fi
