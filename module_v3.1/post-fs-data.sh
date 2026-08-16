#!/system/bin/sh
MODDIR=${0%/*}

# NN v3.1 (merge fix): 最早阶段就拉起采集器。放在任何初始化之前:
# collector 内 dumpsys 失败会自动重试, 无害; 但若先做 init/apply 再拉起,
# 一旦初始化卡住, 采集器就永远不会启动。
sh "$MODDIR/bin/ensure_collector.sh" early

. $MODDIR/common/functions.sh

init_scheduler
apply_mode "balanced" "" "force"

# --- Scene (com.omarea.vtools) standard external-scheduler interface --------
# Scene detects an external scheduler ONLY via these two files:
#   /data/powercfg.sh   - entry point, called as: sh /data/powercfg.sh <mode>
#   /data/powercfg.json - descriptor (name/author/version/state file/entry)
# Without them Scene shows nothing and cannot bind per-app performance modes.
cp -af "$MODDIR/vtools/powercfg.sh" /data/powercfg.sh
chmod 0755 /data/powercfg.sh
cp -af "$MODDIR/vtools/powercfg.json" /data/powercfg.json
chmod 0644 /data/powercfg.json
