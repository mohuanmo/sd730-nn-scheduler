#!/system/bin/sh
################################################################################
# train.sh - Python 环境无关的夜间训练启动器 (v2.1.4 / v3.1.1)
#
# 兼容的 Python 环境 (按优先级):
#   1. PATH 中的 python3 (桌面 / Termux PATH / py2droid wrapper)
#   2. py2droid: /system/usr/bin/python3
#   3. Termux:   /data/data/com.termux/files/usr/bin/python3
#
# 训练引擎自动选择 (v2.1.4):
#   - 有 numpy  -> train.py      (numpy 加速, 300 epochs, batch SGD)
#   - 无 numpy  -> train_pure.py (纯标准库, mini-batch SGD, 手机 1-3 分钟)
#   - 两者都产出相同的 awk 可读模型格式
#
# v3.1.1 变更:
#   - 所有 python 调用加 -u (unbuffered), 强制训练时终端实时显示训练日志
#   - 新增 --v3: 训练 v3 线程级模型 (train_thread.py, 需 numpy)
#
# 用法:  sh bin/train.sh                      (训练)
#        sh bin/train.sh --force              (强制: 跳过待机/样本门槛)
#        sh bin/train.sh --force --v3         (强制训练 v3 线程级模型, 需 numpy)
#        sh bin/train.sh --help
################################################################################

SCRIPT_DIR=$(dirname "$0")
TRAIN_PY="$SCRIPT_DIR/../train.py"
TRAIN_PURE_PY="$SCRIPT_DIR/../train_pure.py"
TRAIN_THREAD_PY="$SCRIPT_DIR/../train_thread.py"

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

# --v3: 训练 v3 线程级模型 (train_thread.py, 依赖 numpy)
V3=""
for _a in "$@"; do
    [ "$_a" = "--v3" ] && V3=1
done
if [ -n "$V3" ]; then
    if "$PY" -c "import numpy" >/dev/null 2>&1; then
        echo "[TRAIN] v3 thread-level model -> train_thread.py (numpy, -u 实时日志)"
        exec "$PY" -u "$TRAIN_THREAD_PY" --force
    else
        echo "[TRAIN] ERROR: train_thread.py 需要 numpy, 未找到 -> v3 无法训练" >&2
        echo "[TRAIN] 安装 numpy: Termux 下 pkg install python numpy" >&2
        exit 1
    fi
fi

# numpy 检测: 有则用加速引擎, 无则纯 Python 引擎
if "$PY" -c "import numpy" >/dev/null 2>&1; then
    echo "[TRAIN] numpy available -> numpy engine (train.py)"
    exec "$PY" -u "$TRAIN_PY" "$@"
else
    echo "[TRAIN] numpy NOT available -> pure-python engine (train_pure.py)"
    echo "[TRAIN] 纯 Python 引擎零依赖, 训练约 1-3 分钟; 模型行为与 numpy 版一致"
    exec "$PY" -u "$TRAIN_PURE_PY" "$@"
fi
