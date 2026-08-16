#!/usr/bin/awk -f
# 线程级标签查看器 v1.0 (v3.2 系列)
# 复刻 train_thread_pure.py / train_thread.py 的 build_dataset() 标签逻辑, 逐字一致
# 用法:  awk -f thread_labels.awk /data/adb/modules/sd730-scheduler/data/collector/*.traw
BEGIN {
    FS = "|"
    FPS = 16.6667; CAP = FPS * 1.05        # 60fps 跑满阈值 ≈17.5ms
    printf "%-18s %-12s %-16s %5s %7s  %-4s %s\n", \
           "pkg", "ts", "thread", "cpu%", "label", "mask", "说明"
    n_ok = 0; n_tot = 0; c_bind = 0; c_mid = 0; c_no = 0
}
{
    # ===== 场景级判定 (第13列fn 14列favg 15列fvar 16列fzero) =====
    skip = 1; lb = 0
    if ($13 >= 10 && $16 <= 0.3 && $14 > 0) {
        skip = 0
        if ($14 <= CAP) { lb = 0 }
        else {
            smooth = 1 - ($15 / 25); if (smooth < 0) smooth = 0; if (smooth > 1) smooth = 1
            if (smooth >= 0.8) lb = 0
            else if (smooth < 0.5) lb = 0.8
            else lb = 0.4
        }
    }
    # ===== 线程级 (第17列起 name|cpu 成对) =====
    for (k = 0; k < 6; k++) {
        name = $(17 + k*2); cpu = $(18 + k*2) + 0
        if (skip) { mask = 0; lab = 0.0; note = "场景无效(帧反馈不可靠)" }
        else if (name == "" || name == "none") { mask = 0; lab = 0.0; note = "空线程槽" }
        else {
            mask = 1
            cap = (cpu < 70) ? cpu/70 : 1
            lab = (lb > 0) ? lb * cap : 0.0
            if (lb == 0) note = "跑满/流畅-不需绑"
            else if (lb == 0.8) note = "卡顿-该绑"
            else note = "中间-轻度"
        }
        printf "%-18s %-12s %-16s %5.0f %7.3f  %-4d %s\n", \
               $2, $1, name, cpu, lab, mask, note
        n_tot++
        if (mask) {
            n_ok++
            if (lab > 0.5) c_bind++
            else if (lab > 0.05) c_mid++
            else c_no++
        }
    }
}
END {
    printf "\n汇总: 有效线程标签 %d / %d (%.0f%%)  |  卡顿该绑=%d  轻度=%d  不需绑=%d\n", \
           n_ok, n_tot, (n_tot > 0) ? n_ok/n_tot*100 : 0, c_bind, c_mid, c_no
    printf "      (有效%%高 = 数据可用; 有效%%≈0 = 全是静止界面, 需游戏/视频攒数据)\n"
}
