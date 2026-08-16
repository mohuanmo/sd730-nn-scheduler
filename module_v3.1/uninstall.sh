#!/system/bin/sh
# Restore safe defaults before the module is removed (applies until reboot)

# CPU governors
for cpu in 0 1 2 3 4 5 6 7; do
    echo "schedutil" > /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor 2>/dev/null
done

# CPU frequency limits (stock SD730 ranges; out-of-range writes are clamped
# or ignored by the kernel, hence the 2>/dev/null guards)
echo "300000" > /sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq 2>/dev/null
echo "1804800" > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
echo "300000" > /sys/devices/system/cpu/cpufreq/policy6/scaling_min_freq 2>/dev/null
echo "2208000" > /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null

# GPU governor + limits (restore the device OPP table's real ceiling; on
# vendor-clipped tables this is e.g. 700MHz instead of the full 825MHz)
echo "msm-adreno-tz" > /sys/class/kgsl/kgsl-3d0/devfreq/governor 2>/dev/null
echo "0" > /sys/class/kgsl/kgsl-3d0/devfreq/min_freq 2>/dev/null
GPU_TMAX=0
for f in $(cat /sys/class/kgsl/kgsl-3d0/devfreq/available_frequencies 2>/dev/null); do
    case "$f" in ''|*[!0-9]*) continue ;; esac
    [ "$f" -gt "$GPU_TMAX" ] && GPU_TMAX=$f
done
[ "$GPU_TMAX" -eq 0 ] && GPU_TMAX=825000000
echo "$GPU_TMAX" > /sys/class/kgsl/kgsl-3d0/devfreq/max_freq 2>/dev/null

# Release the v1.5.3 GPU ultra hard-lock nodes (pwrlevel 0 = fastest, so the
# default range is max_pwrlevel=0 .. min_pwrlevel=num_pwrlevels-1)
GPU_NPL=$(cat /sys/class/kgsl/kgsl-3d0/num_pwrlevels 2>/dev/null)
case "$GPU_NPL" in ''|*[!0-9]*) GPU_NPL=0 ;; esac
echo "0" > /sys/class/kgsl/kgsl-3d0/max_pwrlevel 2>/dev/null
[ "$GPU_NPL" -gt 0 ] 2>/dev/null && echo "$((GPU_NPL - 1))" > /sys/class/kgsl/kgsl-3d0/min_pwrlevel 2>/dev/null
echo "0" > /sys/class/kgsl/kgsl-3d0/force_clk_on 2>/dev/null
echo "0" > /sys/class/kgsl/kgsl-3d0/force_bus_on 2>/dev/null
echo "0" > /sys/class/kgsl/kgsl-3d0/force_rail_on 2>/dev/null
rm -f /data/local/tmp/sd730-gpulock.state /data/local/tmp/sd730-gpuwd.pid 2>/dev/null
rm -f /data/local/tmp/sd730-gpuapp.state 2>/dev/null

# Scheduler boost
echo "0" > /proc/sys/kernel/sched_boost 2>/dev/null

# Release any threads the Thread Pin Engine locked to the big cluster,
# restoring each thread's ORIGINAL mask (field 12) when it was recorded.
# Binding is multi-method on purpose: taskset parses a bare mask as HEX, so if
# that form is unusable in this environment the CPU-list form (decimal
# indices, no hex parsing) is tried next.
u_mask_to_list() {
    local dec=$((0x$1)) i=0 start=-1 prev=-1 out="" seg
    while [ "$i" -lt 32 ]; do
        if [ $((dec & (1 << i))) -ne 0 ]; then
            [ "$start" -lt 0 ] && start=$i
            prev=$i
        elif [ "$start" -ge 0 ]; then
            seg=$start
            [ "$prev" -gt "$start" ] && seg="$start-$prev"
            out=${out:+$out,}$seg
            start=-1
        fi
        i=$((i + 1))
    done
    if [ "$start" -ge 0 ]; then
        seg=$start
        [ "$prev" -gt "$start" ] && seg="$start-$prev"
        out=${out:+$out,}$seg
    fi
    echo "$out"
}
u_bind() {  # tid hexmask
    [ -d "/proc/$1" ] || return 0
    taskset -p "$2" "$1" > /dev/null 2>&1 && return 0
    local l=$(u_mask_to_list "$2")
    [ -n "$l" ] && taskset -pc "$l" "$1" > /dev/null 2>&1 && return 0
    return 1
}
if [ -f /data/local/tmp/sd730-tpin.state ]; then
    while IFS='|' read -r tag tid tgid starttime j ts cpu hs cs target applied orig; do
        [ "$tag" = "TID" ] || continue
        case "$orig" in ''|*[!0-9a-fA-F]*) orig=ff ;; esac
        [ -d "/proc/$tgid/task/$tid" ] && u_bind "$tid" "$orig"
    done < /data/local/tmp/sd730-tpin.state
fi

# Restore the original nice of any correlation-boosted threads
if [ -f /data/local/tmp/sd730-tcorr.state ]; then
    while IFS='|' read -r tag tid tgid start name orig rest; do
        [ "$tag" = "CORS" ] || continue
        case "$orig" in ''|*[!0-9-]*) continue ;; esac
        [ -d "/proc/$tgid/task/$tid" ] && renice -n "$orig" -p "$tid" > /dev/null 2>&1
    done < /data/local/tmp/sd730-tcorr.state
fi

# Clean up runtime state
rm -f /data/local/tmp/sd730-scheduler.log 2>/dev/null
rm -f /data/local/tmp/sd730-tpin.state 2>/dev/null
rm -f /data/local/tmp/sd730-tcorr.state 2>/dev/null
rm -f /data/local/tmp/sd730-tcorr.hist* 2>/dev/null
rm -f /data/local/tmp/sd730-cpuload 2>/dev/null
rm -f /data/local/tmp/sd730-selfm.state 2>/dev/null
rm -f /data/local/tmp/sd730-legacy.state 2>/dev/null

# NN v3.1 cleanup: collector data / v3 runtime files
pkill -f "collector.sh" 2>/dev/null
rm -rf /data/adb/modules/sd730-scheduler/data/collector 2>/dev/null
rm -f /data/local/tmp/sd730-collector.log 2>/dev/null

# Remove the Scene entry point, but only if it belongs to THIS module
# (another scheduler may have legitimately overwritten /data/powercfg.sh).
if grep -q "sd730-scheduler" /data/powercfg.sh 2>/dev/null; then
    rm -f /data/powercfg.sh /data/powercfg.json 2>/dev/null
fi
rm -rf /sdcard/Android/sd730-scheduler 2>/dev/null
