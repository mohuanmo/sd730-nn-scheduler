#!/system/bin/sh
# Patch functions.sh using Python (more reliable than sed/awk)

FUNC="/data/adb/modules/sd730-scheduler/common/functions.sh"
[ -f "$FUNC" ] || { echo "ERROR: $FUNC not found"; exit 1; }

# 智能定位 patch_nn.py: 优先脚本同目录, 回退 /sdcard (v2.1.3)
SCRIPT_DIR=$(dirname "$0")
PATCH_PY=""
[ -f "$SCRIPT_DIR/patch_nn.py" ] && PATCH_PY="$SCRIPT_DIR/patch_nn.py"
[ -z "$PATCH_PY" ] && [ -f "/sdcard/patch_nn.py" ] && PATCH_PY="/sdcard/patch_nn.py"
[ -z "$PATCH_PY" ] && { echo "ERROR: patch_nn.py not found (same dir or /sdcard)"; exit 1; }

# Backup
cp "$FUNC" "${FUNC}.bak" || true

if command -v python3 >/dev/null 2>&1; then
    python3 "$PATCH_PY"
else
    echo "[!] Python3 not found. Install Termux Python or py2droid, or apply patch manually."
    exit 1
fi
