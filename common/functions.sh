#!/system/bin/sh
################################################################################
# SD730 Smart Scheduler - Core Functions v1.5.4
################################################################################

MODDIR="/data/adb/modules/sd730-scheduler"
CORE_LOAD_FILE="$MODDIR/data/collector/.core_load"   # v3.3: 每核使用率 c0|..|c7
CONFIG_DIR="$MODDIR/config"
LEARNING_DB="$CONFIG_DIR/learning.db"
PREDICTION_DB="$CONFIG_DIR/prediction.db"
PREDICTION2_DB="$CONFIG_DIR/prediction2.db"
PREDICTION_TIME_DB="$CONFIG_DIR/prediction_time.db"
PREDICTION_STATE="$CONFIG_DIR/prediction_state.conf"
PREDICTION_CONF="$CONFIG_DIR/prediction.conf"
PREDICTION_ACTIVE="$CONFIG_DIR/prediction_active"
MODE_LEARN_DB="$CONFIG_DIR/mode_learning.db"
MODE_LEARN_CONF="$CONFIG_DIR/mode_learning.conf"
MODE_LEARN_STATE="$CONFIG_DIR/mode_learn_active"
SCENE_VOTE_STATE="$CONFIG_DIR/.scene_vote_state"

# CPU Topology
BIG_CORES="6 7"
LITTLE_CORES="0 1 2 3 4 5"
ALL_CORES="0 1 2 3 4 5 6 7"

# Paths
CPU_BASE="/sys/devices/system/cpu"
GPU_PATH="/sys/class/kgsl/kgsl-3d0"
GPU_MIN="$GPU_PATH/devfreq/min_freq"
GPU_MAX="$GPU_PATH/devfreq/max_freq"
GPU_CUR="$GPU_PATH/devfreq/cur_freq"
GPU_GOVERNOR="$GPU_PATH/devfreq/governor"
# GPU ultra hard-lock: written while the lock is active. Format (v1.5.4+):
# "target_hz|effective_min_hz|locked|relaxed"; the write-first watchdog
# (gpu_lock_watchdog) re-writes every locked node each cycle, then verifies.
GPU_LOCK_STATE="/data/local/tmp/sd730-gpulock.state"
GPU_WD_PID="/data/local/tmp/sd730-gpuwd.pid"
# GPU adaptive scheduler (v1.5.4): per-app GPU tier engine config + the state
# file the main loop publishes for the watchdog ("pkg|mode|tier|min|max|ts").
GPU_SCHED_CONF="$CONFIG_DIR/gpu_sched.conf"
GPU_APP_STATE="/data/local/tmp/sd730-gpuapp.state"
THERMAL_ZONE="/sys/class/thermal"

# Logging (with simple rotation: cap at 256KB, keep the last 200 lines)
LOG_FILE="/data/local/tmp/sd730-scheduler.log"
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || return
    local size=$(wc -c < "$LOG_FILE" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt 262144 ] 2>/dev/null; then
        tail -n 200 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null
    fi
}

################################################################################
# AFFINITY BINDING CORE
#
# Why this exists (the silent-failure postmortem):
#  - taskset ALWAYS parses a bare mask as HEXADECIMAL: "taskset -p 192 <pid>"
#    is read as 0x192 (then clamped by the kernel to the 8 real CPUs -> 0x92),
#    NEVER as decimal 192 (0xc0 = cpu6-7). Any mask that reaches taskset as a
#    decimal string binds the WRONG cores while taskset still exits 0.
#  - The old code fired "taskset ... >/dev/null 2>&1" and trusted it blindly:
#    most paths never checked the exit code, never read the result back from
#    the kernel, never logged anything. On the failure path the smart engine
#    even dropped the thread from its state file, resetting the hot-streak
#    sampling - so ONE failed bind meant the thread never qualified again.
#    Binding died silently AND permanently.
#
# New rules: every affinity write goes through aff_bind_tid(), which
#   1. NORMALIZES the mask (canonical hex; a bare DECIMAL string that would
#      overflow the CPU topology as hex is reinterpreted as decimal, with a
#      warning - the exact "192" trap above heals itself),
#   2. VERIFIES against the kernel: Cpus_allowed is read back (fork-free)
#      before and after binding; a method only counts when the kernel agrees,
#   3. tries the methods that EXIST on stock Android, in order: taskset
#      hex-mask -> busybox taskset hex-mask. (v1.5.2 dropped the "-c"
#      CPU-list form: neither toybox nor busybox taskset implements it -
#      it is a util-linux-only option - so it could never succeed here,
#      and its "Unknown option 'c'" error overwrote the REAL failure.)
#   4. is CPUSET-AWARE (v1.5.2): Android moves app processes between cpuset
#      groups (top-app/foreground/background/...) and every move REWRITES
#      all thread masks to the group mask. A target that shares no CPU with
#      the thread's current group can never be bound (sched_setaffinity
#      fails EINVAL) and a partially-overlapping target is silently clamped
#      by the kernel. Both used to look like a taskset failure and were
#      retried (and re-forked) forever. Now the thread's cpuset mask is
#      read fork-free BEFORE anything is forked:
#        intersection empty  -> DEFER: no fork, throttled log, retried later
#        intersection<target -> CLAMPED: bind the achievable subset (best
#                             effort), keep retrying the full mask later
#   5. LOGS every fallback success and every failure (throttled per tid),
#      with the REAL error of every method tried, and returns a status so
#      callers RETRY on the next cycle instead of dying. AFF_LAST tells the
#      caller the exact outcome: ok|already|clamped|defer|fail|dead|bad-mask.
################################################################################

AFF_NCPUS=""            # cached online-CPU count
AFF_FULLMASK_DEC=0      # cached (1<<NCPUS)-1
AFF_FULLMASK_HEX="ff"
AFF_TASKSET=""          # cached taskset path ("-" = unavailable)
AFF_BUSYBOX=""          # cached busybox path ("-" = unavailable)
AFF_CYCLE=0             # daemon affinity-cycle counter (re-verify cadence)
AFF_OK_LIST=" "         # "tid:mask" pairs whose fallback success was logged
AFF_FAIL_LIST=" "       # "tid:mask" pairs whose failure/defer was already logged
AFF_FAIL_N=0            # total bind failures in this process
AFF_LAST="init"         # outcome of the last aff_bind_tid (see its header)

# Number of online CPUs (parsed from /sys, fork-free, cached).
aff_cpu_count() {
    [ -n "$AFF_NCPUS" ] && { echo "$AFF_NCPUS"; return; }
    local online="" seg a b n=0
    IFS= read -r online < /sys/devices/system/cpu/online 2>/dev/null
    local OLD_AIFS=$IFS
    IFS=','
    for seg in $online; do
        case "$seg" in
            *-*)
                a=${seg%-*}; b=${seg#*-}
                case "$a$b" in ''|*[!0-9]*) continue ;; esac
                n=$((n + b - a + 1))
                ;;
            ''|*[!0-9]*) ;;
            *) n=$((n + 1)) ;;
        esac
    done
    IFS=$OLD_AIFS
    [ "$n" -le 0 ] 2>/dev/null && n=8        # SD730 fallback: 8 cores
    AFF_NCPUS=$n
    AFF_FULLMASK_DEC=$(( (1 << n) - 1 ))
    AFF_FULLMASK_HEX=$(printf "%x" "$AFF_FULLMASK_DEC")
    echo "$AFF_NCPUS"
}

# Normalize any mask-ish value to canonical lowercase hex (no 0x prefix, no
# leading zeros). Accepts "c0" / "C0" / "0xc0" / "00000000,000000c0" and -
# with a loud warning - bare DECIMAL strings like "192" (the classic taskset
# trap: read as hex 0x192 it overflows an 8-core topology, so it must have
# been meant as decimal 192 = 0xc0). Prints nothing on unrecoverable garbage.
aff_mask_normalize() {
    local m=$1 label=${2:-AFF} raw=$1 dec fixed
    m=${m#0x}; m=${m#0X}
    m=${m##*,}                              # lowest chunk of the chunked form
    case "$m" in
        *[A-F]*) m=$(printf '%s' "$m" | tr 'A-F' 'a-f') ;;
    esac
    case "$m" in ''|*[!0-9a-f]*) return 1 ;; esac
    while [ "${m#0}" != "$m" ] && [ ${#m} -gt 1 ]; do m=${m#0}; done
    [ "$m" = "0" ] && return 1              # an empty mask can never be bound
    aff_cpu_count > /dev/null               # ensure the caches are warm
    dec=$((0x$m))
    if [ "$dec" -gt "$AFF_FULLMASK_DEC" ]; then
        fixed=""
        case "$raw" in
            ''|*[!0-9]*) ;;                 # not bare decimal: no reinterpret
            *) fixed=$(printf "%x" "$raw") ;;
        esac
        if [ -n "$fixed" ] && [ $((0x$fixed)) -le "$AFF_FULLMASK_DEC" ] 2>/dev/null; then
            log_msg "[AFF][WARN] mask '$raw' overflows $AFF_NCPUS CPUs as hex (0x$m); reinterpreted as DECIMAL -> 0x$fixed [$label] - fix the caller, taskset masks are HEX"
            m=$fixed
        else
            log_msg "[AFF][WARN] mask '$raw' (0x$m) exceeds the $AFF_NCPUS-CPU topology; clamped to 0x$AFF_FULLMASK_HEX [$label]"
            m=$AFF_FULLMASK_HEX
        fi
    fi
    echo "$m"
}

# hex mask -> taskset CPU-list form ("c0" -> "6-7", "15" -> "0,2,4").
# The list form carries decimal CPU indices, so nothing downstream parses hex.
aff_mask_to_list() {
    local m=$1 dec i=0 start=-1 prev=-1 out="" seg
    case "$m" in ''|*[!0-9a-f]*) return 1 ;; esac
    aff_cpu_count > /dev/null
    dec=$((0x$m))
    while [ "$i" -lt "$AFF_NCPUS" ]; do
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
    [ -n "$out" ] && echo "$out" || return 1
}

# taskset cpulist form ("0-3,6") -> hex mask ("4f"). Fork-free; CPUs past 63
# are ignored (irrelevant on this 8-core chip). Prints nothing on garbage or
# an empty mask (an empty cpuset group is treated as "unknown", not as 0).
aff_list_to_mask() {
    local list=$1 seg a b i dec=0 OLD=$IFS
    IFS=','
    for seg in $list; do
        case "$seg" in
            *-*) a=${seg%-*}; b=${seg#*-} ;;
            *) a=$seg; b=$seg ;;
        esac
        case "$a$b" in ''|*[!0-9]*) IFS=$OLD; return 1 ;; esac
        [ "$b" -gt 63 ] 2>/dev/null && b=63
        i=$a
        while [ "$i" -le "$b" ] 2>/dev/null; do
            dec=$((dec | (1 << i)))
            i=$((i + 1))
        done
    done
    IFS=$OLD
    [ "$dec" -gt 0 ] 2>/dev/null && printf '%x' "$dec" || return 1
}

# A thread's cpuset confinement, fork-free: prints "<group-path>|<hex-mask>",
# or nothing when unknown (no cpuset mounted/readable -> binding stays naive,
# exactly the pre-v1.5.2 behavior). Android facts of life this encodes:
#   /proc/<tid>/cpuset          -> group path, e.g. "/top-app", "/background"
#   /dev/cpuset/<path>/cpus     -> the group's mask (effective_cpus when the
#                                  kernel is new enough to have it)
# sched_setaffinity can never exceed this mask: a disjoint target fails
# EINVAL, a partially overlapping one is silently clamped by the kernel.
aff_cpuset_of() {
    local tid=$1 p base f cpus=""
    IFS= read -r p < "/proc/$tid/cpuset" 2>/dev/null
    case "$p" in /*) ;; *) return 1 ;; esac
    for base in /dev/cpuset /sys/fs/cgroup/cpuset; do
        for f in "$base$p/effective_cpus" "$base$p/cpus"; do
            if [ -r "$f" ]; then
                IFS= read -r cpus < "$f" 2>/dev/null
                [ -n "$cpus" ] && break
            fi
        done
        [ -n "$cpus" ] && break
    done
    [ -n "$cpus" ] || return 1
    local m
    m=$(aff_list_to_mask "$cpus") || return 1
    echo "$p|$m"
}

# Read a thread's current affinity straight from the kernel (fork-free).
# Prints canonical lowercase hex, or nothing when the thread is gone.
aff_read_mask() {
    local f="/proc/$1/status" l m=""
    [ -r "$f" ] || return 1            # dead thread: avoid a redirect error
    while IFS= read -r l; do
        case "$l" in
            Cpus_allowed:*)
                m=${l#*:}
                set -- $m              # collapse whitespace -> $1
                m=${1##*,}             # keep the lowest 32-bit chunk
                while [ "${m#0}" != "$m" ] && [ ${#m} -gt 1 ]; do m=${m#0}; done
                break
                ;;
        esac
    done < "$f"
    [ -n "$m" ] && echo "$m" || return 1
}

# Locate a usable taskset binary (cached; PATH first, well-known paths after).
aff_taskset_bin() {
    if [ -z "$AFF_TASKSET" ]; then
        AFF_TASKSET=$(command -v taskset 2>/dev/null)
        [ -z "$AFF_TASKSET" ] && [ -x /system/bin/taskset ] && AFF_TASKSET=/system/bin/taskset
        [ -z "$AFF_TASKSET" ] && [ -x /vendor/bin/taskset ] && AFF_TASKSET=/vendor/bin/taskset
        [ -z "$AFF_TASKSET" ] && AFF_TASKSET="-"
    fi
    [ "$AFF_TASKSET" = "-" ] && return 1
    echo "$AFF_TASKSET"
}

# Locate a busybox binary (cached; "-" = none). Same caching rules as taskset.
aff_busybox_bin() {
    if [ -z "$AFF_BUSYBOX" ]; then
        AFF_BUSYBOX=$(command -v busybox 2>/dev/null)
        [ -z "$AFF_BUSYBOX" ] && [ -x /system/bin/busybox ] && AFF_BUSYBOX=/system/bin/busybox
        [ -z "$AFF_BUSYBOX" ] && [ -x /vendor/bin/busybox ] && AFF_BUSYBOX=/vendor/bin/busybox
        [ -z "$AFF_BUSYBOX" ] && AFF_BUSYBOX="-"
    fi
    [ "$AFF_BUSYBOX" = "-" ] && return 1
    echo "$AFF_BUSYBOX"
}

# A success reaches the log only when a FALLBACK method had to be used: a
# working primary taskset is the norm, but "primary broken, fallback works"
# is exactly the environment fact worth recording (once per tid per process).
aff_log_ok() {   # tid mask method label
    [ "$3" = "taskset-hex" ] && return
    case "$AFF_OK_LIST" in *" $1:$2 "*) return ;; esac
    AFF_OK_LIST="${AFF_OK_LIST}$1:$2 "
    [ ${#AFF_OK_LIST} -gt 900 ] && AFF_OK_LIST=" "
    log_msg "[AFF] tid=$1 -> 0x$2 bound via fallback '$3' [$4] (primary taskset unusable here)"
}

# Failures always reach the log: the first failure per (tid,mask) carries the
# tool's own error text, and every 25th failure prints a summary - the engine
# keeps retrying, so a persistent failure stays visible without log flooding.
aff_log_fail() {   # tid mask label err
    AFF_FAIL_N=$((AFF_FAIL_N + 1))
    case "$AFF_FAIL_LIST" in
        *" $1:$2 "*) ;;
        *)
            AFF_FAIL_LIST="${AFF_FAIL_LIST}$1:$2 "
            [ ${#AFF_FAIL_LIST} -gt 900 ] && AFF_FAIL_LIST=" "
            log_msg "[AFF][FAIL] tid=$1 -> 0x$2 [$3]: all bind methods failed (total ${AFF_FAIL_N}). last error: ${4:-unknown}"
            ;;
    esac
    if [ $((AFF_FAIL_N % 25)) -eq 0 ]; then
        log_msg "[AFF][FAIL] $AFF_FAIL_N affinity bind failures so far - the engine keeps retrying every cycle"
    fi
}

# Deferral (target currently unreachable under the thread's cpuset): logged
# once per (tid,mask), no tool is ever forked for these - the kernel CANNOT
# accept the mask today, so retrying taskset would be pure fork spam.
aff_log_defer() {   # tid target current cpuset-path cpuset-mask label
    case "$AFF_FAIL_LIST" in *" $1:$2 "*) return ;; esac
    AFF_FAIL_LIST="${AFF_FAIL_LIST}$1:$2 "
    [ ${#AFF_FAIL_LIST} -gt 900 ] && AFF_FAIL_LIST=" "
    log_msg "[AFF][DEFER] tid=$1 -> 0x$2 [$6]: unreachable - thread confined to cpuset '$4' (0x$5), current mask 0x$3; retried when Android moves the group"
}

# Clamp (kernel/cpuset allows only a subset of the target): the achievable
# subset was bound (or already was). Logged once per (tid,target) - the full
# target keeps being retried, so when the cpuset widens the pin completes.
aff_log_clamped() {   # tid target achievable cpuset-path cpuset-mask label method
    case "$AFF_OK_LIST" in *" $1:$2 "*) return ;; esac
    AFF_OK_LIST="${AFF_OK_LIST}$1:$2 "
    [ ${#AFF_OK_LIST} -gt 900 ] && AFF_OK_LIST=" "
    log_msg "[AFF][CLAMPED] tid=$1 -> 0x$2 [$6]: cpuset '$4' (0x$5) allows only 0x$3 - bound the subset via $7; full mask retried later"
}

# Bind ONE thread to a CPU mask: normalize -> fast-path read-back -> cpuset
# reality check -> taskset hex -> busybox hex, until the KERNEL confirms the
# mask. Never kills the caller; returns 1 on failure so the engine retries on
# the next cycle instead of dropping the thread (the old death spiral: drop
# -> streak reset -> never qualifies again -> silent permanent failure).
# AFF_LAST records the exact outcome for the caller's counters:
#   ok       bound and kernel-verified              (returns 0)
#   already  kernel already had the target mask     (returns 0, zero forks)
#   clamped  cpuset allows only a subset; bound it  (returns 1, best effort)
#   defer    cpuset allows NONE of the target       (returns 1, zero forks)
#   fail     every available method failed          (returns 1)
#   dead     thread is gone                         (returns 1, caller prunes)
#   bad-mask / bad-tid                              (returns 1)
# Usage: aff_bind_tid <tid> <mask-any-form> [label]
aff_bind_tid() {
    AFF_LAST="fail"
    local tid=$1 raw=$2 label=${3:-AFF}
    case "$tid" in ''|*[!0-9]*) AFF_LAST="bad-tid"; return 1 ;; esac
    local mask=$(aff_mask_normalize "$raw" "$label")
    if [ -z "$mask" ]; then
        AFF_LAST="bad-mask"
        aff_log_fail "$tid" "??" "$label" "invalid mask '$raw'"
        return 1
    fi
    local cur=$(aff_read_mask "$tid")
    [ -z "$cur" ] && { AFF_LAST="dead"; return 1; }      # thread died: caller prunes
    [ "$cur" = "$mask" ] && { AFF_LAST="already"; return 0; }  # already bound: zero forks

    # ---- cpuset reality check (fork-free) --------------------------------
    # Android rewrites every thread mask to the cpuset group mask on each
    # fg/bg move; while a thread sits in a restrictive group our target may
    # be partially or wholly impossible. Detect that BEFORE forking a tool:
    # wholly impossible targets are deferred without a single fork, partial
    # ones are bound to the achievable subset instead of erroring out.
    local want=$mask cs cs_path="" cs_mask="" ach=""
    cs=$(aff_cpuset_of "$tid")
    if [ -n "$cs" ]; then
        cs_path=${cs%%|*}; cs_mask=${cs#*|}
        aff_cpu_count > /dev/null
        ach=$(printf '%x' $((0x$mask & 0x$cs_mask)))
        if [ "$ach" = "0" ]; then
            AFF_LAST="defer"
            aff_log_defer "$tid" "$mask" "$cur" "$cs_path" "$cs_mask" "$label"
            return 1
        fi
        if [ "$ach" != "$mask" ]; then
            if [ "$cur" = "$ach" ]; then
                AFF_LAST="clamped"
                aff_log_clamped "$tid" "$mask" "$ach" "$cs_path" "$cs_mask" "$label" "(already at best subset)"
                return 1
            fi
            want=$ach        # the kernel would clamp to this anyway: ask for it
        fi
    fi

    # ---- methods: hex mask only. The "-c" CPU-list form is gone: toybox ----
    # ---- AND busybox taskset only implement the hex form, so "-c" could ----
    # ---- never succeed on stock Android - it only wasted a fork and ---------
    # ---- overwrote the real error with "Unknown option 'c'". ----------------
    local ts bb err errs=""
    ts=$(aff_taskset_bin)
    if [ -n "$ts" ]; then
        err=$("$ts" -p "$want" "$tid" 2>&1)
        if [ $? -eq 0 ]; then
            cur=$(aff_read_mask "$tid")
            if [ "$cur" = "$want" ]; then
                if [ "$want" = "$mask" ]; then
                    AFF_LAST="ok"; aff_log_ok "$tid" "$mask" "taskset-hex" "$label"; return 0
                fi
                AFF_LAST="clamped"
                aff_log_clamped "$tid" "$mask" "$ach" "$cs_path" "$cs_mask" "$label" "taskset-hex"
                return 1
            fi
            err="exit 0 but kernel shows 0x${cur:-?}"
        fi
        errs="taskset-hex: ${err:-unknown}"
    fi
    bb=$(aff_busybox_bin)
    if [ -n "$bb" ]; then
        err=$("$bb" taskset -p "$want" "$tid" 2>&1)
        if [ $? -eq 0 ]; then
            cur=$(aff_read_mask "$tid")
            if [ "$cur" = "$want" ]; then
                if [ "$want" = "$mask" ]; then
                    AFF_LAST="ok"; aff_log_ok "$tid" "$mask" "busybox-hex" "$label"; return 0
                fi
                AFF_LAST="clamped"
                aff_log_clamped "$tid" "$mask" "$ach" "$cs_path" "$cs_mask" "$label" "busybox-hex"
                return 1
            fi
            err="exit 0 but kernel shows 0x${cur:-?}"
        fi
        errs="${errs:+$errs; }busybox-hex: ${err:-unknown}"
    fi
    aff_log_fail "$tid" "$mask" "$label" "$errs"
    return 1
}

# One-time environment line at daemon start: which bind methods exist here.
aff_env_log() {
    local ts=$(aff_taskset_bin) n=$(aff_cpu_count) bb=$(aff_busybox_bin)
    log_msg "[AFF] binder ready: cpus=$n fullmask=0x$AFF_FULLMASK_HEX taskset=${ts:-NONE} busybox=${bb:-none} (methods: taskset-hex -> busybox-hex; cpuset-aware defer/clamp)"
}

# Warm the caches so per-bind subshells inherit them (no repeated lookups).
aff_cpu_count > /dev/null 2>&1
aff_taskset_bin > /dev/null 2>&1
aff_busybox_bin > /dev/null 2>&1

# Force learning.db into a writable state. The DB lives on /data, where other
# root tools can lock it (chattr +i/+a) or strip its write permission; once
# that happens every update fails silently and learning freezes while the
# rest of the daemon keeps running. Called before EVERY write to the DB.
ensure_learning_db_writable() {
    # Path was replaced by a directory/symlink/special file: remove it, the
    # caller recreates the file.
    if [ -L "$LEARNING_DB" ] || { [ -e "$LEARNING_DB" ] && [ ! -f "$LEARNING_DB" ]; }; then
        rm -rf "$LEARNING_DB" 2>/dev/null
    fi
    # Break chattr +i/+a locks (toybox/busybox chattr; no-op if unavailable)
    chattr -i -a "$LEARNING_DB" 2>/dev/null
    # Restore write permission
    chmod 0644 "$LEARNING_DB" 2>/dev/null
    return 0
}

# Force prediction.db into a writable state. The DB lives on /data, where other
# root tools can lock it (chattr +i/+a) or strip its write permission; once
# that happens every update fails silently and prediction learning freezes
# while the rest of the daemon keeps running. Called before EVERY write to
# the DB.
ensure_prediction_db_writable() {
    # Path was replaced by a directory/symlink/special file: remove it, the
    # caller recreates the file.
    if [ -L "$PREDICTION_DB" ] || { [ -e "$PREDICTION_DB" ] && [ ! -f "$PREDICTION_DB" ]; }; then
        rm -rf "$PREDICTION_DB" 2>/dev/null
    fi
    # Break chattr +i/+a locks (toybox/busybox chattr; no-op if unavailable)
    chattr -i -a "$PREDICTION_DB" 2>/dev/null
    # Restore write permission
    chmod 0644 "$PREDICTION_DB" 2>/dev/null
    return 0
}

# Force prediction_state.conf into a writable state. The file lives on /data,
# where other root tools can lock it (chattr +i/+a) or strip its write
# permission; once that happens every update fails silently and prediction
# accounting freezes while the rest of the daemon keeps running. Called
# before EVERY write to the file.
ensure_prediction_state_writable() {
    # Path was replaced by a directory/symlink/special file: remove it, the
    # caller recreates the file.
    if [ -L "$PREDICTION_STATE" ] || { [ -e "$PREDICTION_STATE" ] && [ ! -f "$PREDICTION_STATE" ]; }; then
        rm -rf "$PREDICTION_STATE" 2>/dev/null
    fi
    # Break chattr +i/+a locks (toybox/busybox chattr; no-op if unavailable)
    chattr -i -a "$PREDICTION_STATE" 2>/dev/null
    # Restore write permission
    chmod 0644 "$PREDICTION_STATE" 2>/dev/null
    return 0
}

# Force mode_learning.db into a writable state. The DB lives on /data, where
# other root tools can lock it (chattr +i/+a) or strip its write permission;
# once that happens every update fails silently and mode learning freezes
# while the rest of the daemon keeps running. Called before EVERY write to
# the DB.
ensure_mode_learn_db_writable() {
    # Path was replaced by a directory/symlink/special file: remove it, the
    # caller recreates the file.
    if [ -L "$MODE_LEARN_DB" ] || { [ -e "$MODE_LEARN_DB" ] && [ ! -f "$MODE_LEARN_DB" ]; }; then
        rm -rf "$MODE_LEARN_DB" 2>/dev/null
    fi
    # Break chattr +i/+a locks (toybox/busybox chattr; no-op if unavailable)
    chattr -i -a "$MODE_LEARN_DB" 2>/dev/null
    # Restore write permission
    chmod 0644 "$MODE_LEARN_DB" 2>/dev/null
    return 0
}

# Safe config read: key=val from file
read_cfg() {
    local file=$1
    local key=$2
    local default=$3
    if [ -f "$file" ]; then
        local val=$(grep "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
        [ -n "$val" ] && echo "$val" || echo "$default"
    else
        echo "$default"
    fi
}

# Get temperature (Celsius). Prefer CPU/SoC thermal zones: taking the MAX of
# ALL zones picks up modem/PA/camera sensors that legitimately sit at 60-90C
# on SD730 devices, which permanently tripped the >65C learning penalty and
# the 55C prediction limit. Zone match pattern is configurable via
# thermal_zone_pattern in prediction.conf (fallback: max of all zones).
get_temperature() {
    local pattern=$(read_cfg "$PREDICTION_CONF" "thermal_zone_pattern" "cpu|soc|apss")
    local max_temp=0 temp zone type
    # Pass 1: only zones whose type matches the SoC/CPU pattern
    for zone in $THERMAL_ZONE/thermal_zone*/temp; do
        [ -f "$zone" ] || continue
        type=$(cat "${zone%/temp}/type" 2>/dev/null)
        if echo "$type" | grep -qiE "$pattern" 2>/dev/null; then
            temp=$(cat "$zone" 2>/dev/null)
            case "$temp" in ''|*[!0-9]*) continue ;; esac
            [ "$temp" -gt "$max_temp" ] && max_temp=$temp
        fi
    done
    if [ "$max_temp" -gt 0 ]; then
        echo $((max_temp / 1000))
        return
    fi
    # Pass 2 (fallback): max of all zones (original behavior)
    for zone in $THERMAL_ZONE/thermal_zone*/temp; do
        if [ -f "$zone" ]; then
            temp=$(cat "$zone" 2>/dev/null)
            if [ -n "$temp" ] && [ "$temp" -gt "$max_temp" ] 2>/dev/null; then
                max_temp=$temp
            fi
        fi
    done
    echo $((max_temp / 1000))
}

# Get battery level (0-100)
get_battery_level() {
    cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo "50"
}

# Get battery status
get_battery_status() {
    cat /sys/class/power_supply/battery/status 2>/dev/null || echo "Unknown"
}

# Get foreground app package name (multi-method fallback)
get_foreground_app() {
    local pkg=""
    # Android 10+ mResumedActivity
    pkg=$(dumpsys activity activities 2>/dev/null | grep -E "mResumedActivity" | head -1 | sed -n 's/.*{[^}]* \([^ ]*\)\/.*/\1/p')
    # Android 12+ mFocusedWindow / mFocusedApp fallback
    [ -z "$pkg" ] && pkg=$(dumpsys window displays 2>/dev/null | grep -E "mFocusedWindow" | head -1 | sed -n 's/.* \([^ ]*\)\/.*/\1/p')
    [ -z "$pkg" ] && pkg=$(dumpsys activity activities 2>/dev/null | grep -E "mFocusedApp" | head -1 | sed -n 's/.*[[:space:]]\([^ ]*\)\/.*/\1/p')
    # Last-resort fallback: cpuset membership scan. The foreground app's
    # processes sit in the top-app cpuset; if dumpsys parsing fails (immersive
    # fullscreen games on some ROMs break the regexes above) the WHOLE module
    # used to go silently blind - no affinity, no learning, no pinning.
    if [ -z "$pkg" ]; then
        local pdir cs fcmd
        for pdir in /proc/[0-9]*; do
            cs=""
            IFS= read -r cs < "$pdir/cpuset" 2>/dev/null
            case "$cs" in *top-app*) ;; *) continue ;; esac
            fcmd=""
            IFS= read -r fcmd < "$pdir/cmdline" 2>/dev/null
            case "$fcmd" in
                *.*) pkg=$fcmd; break ;;
            esac
        done
    fi
    # Basic validation: must contain a dot and no spaces
    case "$pkg" in
        *.*)
            echo "$pkg" | tr -d '[:space:]'
            ;;
        *)
            echo ""
            ;;
    esac
}

# Get app PIDs via /proc cmdline scan.
# Unlike "ps -o NAME" (which reads comm, truncated to 15 chars by the kernel),
# cmdline holds the FULL process name, so long package names like
# com.tencent.mobileqq match correctly. Also matches sub-processes (pkg:remote).
get_app_pids() {
    local pkg=$1
    [ -z "$pkg" ] && return
    local pid_dir cmd
    for pid_dir in /proc/[0-9]*; do
        cmd=""
        IFS= read -r cmd < "$pid_dir/cmdline" 2>/dev/null
        case "$cmd" in
            "$pkg"|"$pkg":*) echo "${pid_dir#/proc/}" ;;
        esac
    done
}

# Get app CPU load (0-100) as an INSTANTANEOUS value from /proc/<pid>/stat
# jiffies deltas between scheduler cycles. The old "ps -A -o PID,%CPU" approach
# reads toybox's lifetime average, which decays toward 0 for long-running apps
# and left every learned app with avg_cpu=0 (learning was effectively blind to
# CPU usage). State is kept per foreground package in a tmpfs file.
CPU_LOAD_STATE="/data/local/tmp/sd730-cpuload"
get_app_cpu_load() {
    local pkg=$1
    [ -z "$pkg" ] && echo "0" && return
    local total_jiffies=0 pid rest j
    for pid in $(get_app_pids "$pkg"); do
        [ -f "/proc/$pid/stat" ] || continue
        # field 2 (comm) may contain spaces/parens; cutting through the last
        # ')' shifts fields by 2, so utime/stime become fields 12/13.
        rest=$(cut -d')' -f2- /proc/$pid/stat 2>/dev/null)
        [ -n "$rest" ] || continue
        j=$(echo "$rest" | awk '{print $12+$13}' 2>/dev/null)
        case "$j" in ''|*[!0-9]*) j=0 ;; esac
        total_jiffies=$((total_jiffies + j))
    done
    local now=$(date +%s)
    local prev_pkg="" prev_total=0 prev_ts=0
    if [ -f "$CPU_LOAD_STATE" ]; then
        prev_pkg=$(cut -d'|' -f1 "$CPU_LOAD_STATE" 2>/dev/null)
        prev_total=$(cut -d'|' -f2 "$CPU_LOAD_STATE" 2>/dev/null)
        prev_ts=$(cut -d'|' -f3 "$CPU_LOAD_STATE" 2>/dev/null)
    fi
    echo "${pkg}|${total_jiffies}|${now}" > "$CPU_LOAD_STATE" 2>/dev/null
    case "$prev_total" in ''|*[!0-9]*) prev_total=0 ;; esac
    case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
    local elapsed=$((now - prev_ts))
    local delta=$((total_jiffies - prev_total))
    if [ "$prev_pkg" != "$pkg" ] || [ "$prev_ts" -le 0 ] || \
       [ "$elapsed" -le 0 ] || [ "$delta" -lt 0 ]; then
        echo "0"   # first sample for this app / clock skew / process restart
        return
    fi
    # USER_HZ=100 on Android: jiffies/s == % of one core
    local cpu=$((delta / elapsed))
    [ "$cpu" -gt 100 ] && cpu=100
    echo "$cpu"
}

# Get app memory in MB
get_app_memory() {
    local pkg=$1
    [ -z "$pkg" ] && echo "0" && return
    local total_mem=0
    for pid in $(get_app_pids "$pkg"); do
        [ -d "/proc/$pid" ] || continue
        local mem=$(cat /proc/$pid/status 2>/dev/null | grep VmRSS | awk '{print $2}')
        [ -n "$mem" ] && total_mem=$((total_mem + mem))
    done
    echo $((total_mem / 1024))
}

# Get app thread count. Counts /proc/<pid>/task/<tid> via shell globbing
# instead of "ls | grep -c '^[0-9]\+$'": toybox grep's BRE \+ support is
# unreliable, which silently returned 0 threads for every app.
get_app_threads() {
    local pkg=$1
    [ -z "$pkg" ] && echo "0" && return
    local total_threads=0
    local pid t
    for pid in $(get_app_pids "$pkg"); do
        [ -d "/proc/$pid/task" ] || continue
        for t in /proc/$pid/task/[0-9]*; do
            [ -d "$t" ] && total_threads=$((total_threads + 1))
        done
    done
    echo "$total_threads"
}

# Get GPU load (0-100). The kgsl node prints "5 %" on some kernels, so strip
# the percent sign AND any whitespace/CR, then validate - a trailing space used
# to leak into status output and arithmetic.
get_gpu_load() {
    local load=$(cat /sys/class/kgsl/kgsl-3d0/gpu_busy_percentage 2>/dev/null | tr -d '% \r\t')
    case "$load" in ''|*[!0-9-]*) load=0 ;; esac
    if [ "$load" -lt 0 ] 2>/dev/null; then
        load=0
    elif [ "$load" -gt 100 ] 2>/dev/null; then
        load=100
    fi
    echo "$load"
}

################################################################################
# LEARNING ENGINE
################################################################################

init_learning_db() {
    ensure_learning_db_writable
    [ ! -f "$LEARNING_DB" ] && touch "$LEARNING_DB" 2>/dev/null
}

init_app_learning() {
    local pkg=$1
    [ -z "$pkg" ] && return
    init_learning_db
    if ! awk -F'|' -v pkg="$pkg" '$1 == pkg {found=1} END {exit !found}' "$LEARNING_DB" 2>/dev/null; then
        echo "${pkg}|0|50|50|30|0|0|0|$(date +%s)" >> "$LEARNING_DB"
    fi
}

# Atomically update learning database (safe for pkg names with dots)
safe_update_learning_db() {
    local pkg=$1
    local new_line=$2
    local tmp="${LEARNING_DB}.tmp.$$"
    ensure_learning_db_writable
    awk -F'|' -v pkg="$pkg" '$1 != pkg' "$LEARNING_DB" > "$tmp" 2>/dev/null || true
    echo "$new_line" >> "$tmp"
    mv "$tmp" "$LEARNING_DB"
}

update_app_learning() {
    local pkg=$1
    local cpu_load=$2
    local mem_mb=$3
    local threads=$4
    local gpu_load=$5
    local temp=$6
    local battery=$7

    [ -z "$pkg" ] && return
    init_app_learning "$pkg"

    local alpha=30

    # Calculate observed probabilities. threads is a raw count (can easily
    # reach 60-100+ now that counting works); cap its contribution at +20,
    # otherwise threads/2 alone saturates observed_big for almost every app.
    local t=$threads
    case "$t" in ''|*[!0-9]*) t=0 ;; esac
    [ "$t" -gt 40 ] && t=40
    local observed_big=$((cpu_load * 8 / 10 + t / 2 + gpu_load * 3 / 10))
    [ "$observed_big" -gt 100 ] && observed_big=100
    [ "$observed_big" -lt 0 ] && observed_big=0

    local observed_little=$((100 - observed_big))
    [ "$observed_little" -gt 100 ] && observed_little=100
    [ "$observed_little" -lt 0 ] && observed_little=0

    # GPU affinity is the raw observed load now (the old "+20" fixed bias
    # inflated every app's GPU% and skewed the mode-learning cross-checks).
    local observed_gpu=$gpu_load
    [ "$observed_gpu" -gt 100 ] && observed_gpu=100
    [ "$observed_gpu" -lt 0 ] && observed_gpu=0

    # NOTE: no sample-time temperature/battery penalties here anymore. They
    # shrank observed_big WITHOUT raising observed_little (so big+little
    # drifted below 100) and baked a momentary thermal episode permanently
    # into the long-term profile - while the same heat was ALSO handled by
    # the real-time guards (apply_mode 75C/85C downgrades, prediction
    # temp_limit, thread-pin release_temp), i.e. double-punished. Thermal and
    # battery reactions belong to the real-time path only; the learned
    # profile keeps the big+little=100 invariant.

    local line=$(awk -F'|' -v pkg="$pkg" '$1 == pkg' "$LEARNING_DB" 2>/dev/null)
    [ -z "$line" ] && return

    local old_count=$(echo "$line" | cut -d'|' -f2)
    local old_big=$(echo "$line" | cut -d'|' -f3)
    local old_little=$(echo "$line" | cut -d'|' -f4)
    local old_gpu=$(echo "$line" | cut -d'|' -f5)
    local old_cpu=$(echo "$line" | cut -d'|' -f6)
    local old_mem=$(echo "$line" | cut -d'|' -f7)
    local old_threads=$(echo "$line" | cut -d'|' -f8)

    [ -z "$old_count" ] && old_count=0
    [ -z "$old_big" ] && old_big=50
    [ -z "$old_little" ] && old_little=50
    [ -z "$old_gpu" ] && old_gpu=30
    [ -z "$old_cpu" ] && old_cpu=0
    [ -z "$old_mem" ] && old_mem=0
    [ -z "$old_threads" ] && old_threads=0

    local new_big=$(((alpha * observed_big + (100 - alpha) * old_big) / 100))
    local new_little=$(((alpha * observed_little + (100 - alpha) * old_little) / 100))
    local new_gpu=$(((alpha * observed_gpu + (100 - alpha) * old_gpu) / 100))
    local new_count=$((old_count + 1))
    local new_cpu=0
    local new_mem=0
    local new_threads=0
    if [ "$new_count" -gt 0 ] 2>/dev/null; then
        new_cpu=$(((old_cpu * old_count + cpu_load) / new_count))
        new_mem=$(((old_mem * old_count + mem_mb) / new_count))
        new_threads=$(((old_threads * old_count + threads) / new_count))
    fi

    safe_update_learning_db "$pkg" "${pkg}|${new_count}|${new_big}|${new_little}|${new_gpu}|${new_cpu}|${new_mem}|${new_threads}|$(date +%s)"
}

# NOTE: outputs COMMA-separated "big,little,gpu" because every caller parses
# with cut -d',' (cut -d'|' -f3,4,5 would keep '|' as the output delimiter,
# silently breaking all numeric comparisons downstream).
get_app_probabilities() {
    local pkg=$1
    local line=$(awk -F'|' -v pkg="$pkg" '$1 == pkg' "$LEARNING_DB" 2>/dev/null)
    if [ -n "$line" ]; then
        echo "$line" | awk -F'|' '{print $3","$4","$5}'
    else
        echo "50,50,30"
    fi
}

get_affinity_mask() {
    local pkg=$1
    local mode=$2
    local probs big_prob little_prob

    # Insufficient learning data: keep the app on the LITTLE cluster. The old
    # "don't restrict what you don't know" default (0xff) let every cold
    # thread of an unknown app wander onto the two A76s; now the big cores
    # are ONLY handed out per-thread by the Thread Pin Engine, so an unknown
    # app's bulk starts on cpu0-5 and its genuinely hot threads are pinned
    # within a couple of cycles. (powersave already behaved this way.)
    local ms_min=${TP_MASK_MIN_SAMPLES:-6}
    case "$ms_min" in ''|*[!0-9]*) ms_min=6 ;; esac
    local lcnt=0
    if [ -f "$LEARNING_DB" ]; then
        lcnt=$(awk -F'|' -v pkg="$pkg" '$1 == pkg {print $2; exit}' "$LEARNING_DB" 2>/dev/null)
    fi
    case "$lcnt" in ''|*[!0-9]*) lcnt=0 ;; esac
    if [ "$lcnt" -lt "$ms_min" ]; then
        printf "3f"
        return
    fi

    probs=$(get_app_probabilities "$pkg")
    big_prob=$(echo "$probs" | cut -d',' -f1)
    little_prob=$(echo "$probs" | cut -d',' -f2)

    # Sanitize: a corrupt/non-numeric DB value falls back to neutral 50
    case "$big_prob" in ''|*[!0-9]*) big_prob=50 ;; esac
    case "$little_prob" in ''|*[!0-9]*) little_prob=50 ;; esac

    # Two-stage weighted mask synthesis (v1.5.3):
    #   stage 1 - LITTLE ladder: cpu0..5 light up one by one as little_prob
    #             clears per-mode thresholds; a heavy app (big_prob > floor)
    #             instead gets the WHOLE little cluster as its base, because
    #             little_prob=100-big_prob would otherwise leave it a single
    #             little core (the v1.5.2 "narrow mask for heavy apps" bug).
    #   stage 2 - big-core bonus: cpu6/cpu7 are added ONLY when big_prob
    #             clears deliberately high per-mode gates (big6/big7). The
    #             gates sit far above v1.5.2's (60/80), so big cores become
    #             RARE in the coarse mask - per-thread pins from the Thread
    #             Pin Engine are the primary big-core channel - yet a
    #             genuinely big-heavy app keeps its path (the learning data
    #             still steers the outcome instead of being ignored).
    # floor=101 / big6=101 disable that stage for the mode (prob is <=100).
    local mask=0 base step floor big6 big7
    case "$mode" in
        powersave)   base=50; step=8;  floor=101; big6=101; big7=101 ;;
        balanced)    base=30; step=10; floor=60;  big6=85;  big7=95  ;;
        performance) base=25; step=10; floor=55;  big6=80;  big7=90  ;;
        ultra|*)     base=20; step=10; floor=50;  big6=75;  big7=85  ;;
    esac
    if [ "$big_prob" -gt "$floor" ] 2>/dev/null; then
        mask=63                        # heavy app: whole little cluster base
    else
        for i in 0 1 2 3 4 5; do
            local threshold=$((base + i * step))
            [ "$little_prob" -gt "$threshold" ] && mask=$((mask | (1 << i)))
        done
        [ "$mask" -eq 0 ] && mask=63
    fi
    [ "$big_prob" -gt "$big6" ] 2>/dev/null && mask=$((mask | (1 << 6)))   # + cpu6
    [ "$big_prob" -gt "$big7" ] 2>/dev/null && mask=$((mask | (1 << 7)))   # + cpu7
    printf "%02x" "$mask"
}

################################################################################
# PREDICTION ENGINE
################################################################################

init_prediction() {
    mkdir -p "$CONFIG_DIR"
    ensure_prediction_db_writable
    ensure_prediction_state_writable
    [ ! -f "$PREDICTION_DB" ] && touch "$PREDICTION_DB"
    [ ! -f "$PREDICTION2_DB" ] && touch "$PREDICTION2_DB" 2>/dev/null
    [ ! -f "$PREDICTION_TIME_DB" ] && touch "$PREDICTION_TIME_DB" 2>/dev/null
    [ ! -f "$PREDICTION_STATE" ] && touch "$PREDICTION_STATE"
    if [ ! -f "$PREDICTION_CONF" ]; then
        cat > "$PREDICTION_CONF" <<'EOF'
prediction_enabled=true
confidence_threshold=60
max_predictions_per_hour=30
max_false_positive_rate=40
fp_min_predictions=8
fp_lockout_minutes=30
temp_limit=55
battery_limit=30
cooldown_seconds=5
prediction_boost_little_min=1000000
prediction_boost_duration=3
prediction_validation_seconds=180
thermal_zone_pattern=cpu|soc|apss
time_bucket_hours=2
time_weight=2
second_order_enabled=true
second_order_min_total=2
EOF
    else
        # Migrate configs written by older versions: append keys they lack.
        grep -q '^fp_min_predictions='      "$PREDICTION_CONF" 2>/dev/null || echo "fp_min_predictions=8"        >> "$PREDICTION_CONF"
        grep -q '^fp_lockout_minutes='      "$PREDICTION_CONF" 2>/dev/null || echo "fp_lockout_minutes=30"       >> "$PREDICTION_CONF"
        grep -q '^time_bucket_hours='       "$PREDICTION_CONF" 2>/dev/null || echo "time_bucket_hours=2"         >> "$PREDICTION_CONF"
        grep -q '^time_weight='             "$PREDICTION_CONF" 2>/dev/null || echo "time_weight=2"               >> "$PREDICTION_CONF"
        grep -q '^second_order_enabled='    "$PREDICTION_CONF" 2>/dev/null || echo "second_order_enabled=true"   >> "$PREDICTION_CONF"
        grep -q '^second_order_min_total='  "$PREDICTION_CONF" 2>/dev/null || echo "second_order_min_total=2"    >> "$PREDICTION_CONF"
    fi
}

# Current time-of-day bucket (0 .. 24/time_bucket_hours-1)
prediction_time_bucket() {
    local hours=$(read_cfg "$PREDICTION_CONF" "time_bucket_hours" "2")
    case "$hours" in ''|*[!0-9]*) hours=2 ;; esac
    [ "$hours" -lt 1 ] 2>/dev/null && hours=1
    [ "$hours" -gt 24 ] 2>/dev/null && hours=24
    local h=$(date +%H)
    h=${h#0}
    [ -z "$h" ] && h=0
    echo $((h / hours))
}

# Cap a prediction DB (drop least-recently-updated entries).
# $1=file $2=field index of last_ts
prune_prediction_db() {
    [ -f "$1" ] || return
    local tsf=${2:-4}
    local lines=$(wc -l < "$1" 2>/dev/null)
    case "$lines" in ''|*[!0-9]*) return ;; esac
    [ "$lines" -le 600 ] && return
    local tmp="$1.tmp.$$"
    sort -t'|' -k${tsf},${tsf} -rn "$1" 2>/dev/null | head -n 400 > "$tmp" \
        && mv "$tmp" "$1" 2>/dev/null
    log_msg "[PREDICT] $(basename "$1") pruned ($lines -> 400 entries)"
}

# Update Markov chain: prev -> curr.
# Also feeds the two context extensions:
#   - prediction_time.db : (prev,curr,bucket) counts - time-of-day awareness
#   - prediction2.db     : (prev2,prev1,next) counts - second-order context,
#                          i.e. "the app before the previous app" history
# Usage: update_prediction_chain <prev> <curr> [prev2]
update_prediction_chain() {
    local prev=$1
    local curr=$2
    local prev2=$3
    if [ -z "$prev" ] || [ -z "$curr" ]; then
        return
    fi
    [ "$prev" = "$curr" ] && return

    ensure_prediction_db_writable
    local now=$(date +%s)
    local line=$(awk -F'|' -v p="$prev" -v c="$curr" '$1 == p && $2 == c' "$PREDICTION_DB" 2>/dev/null)

    if [ -n "$line" ]; then
        local count=$(echo "$line" | cut -d'|' -f3)
        local last_ts=$(echo "$line" | cut -d'|' -f4)
        local avg_interval=$(echo "$line" | cut -d'|' -f5)
        [ -z "$count" ] && count=0
        [ -z "$last_ts" ] && last_ts=$now
        [ -z "$avg_interval" ] && avg_interval=0
        local new_count=$((count + 1))
        local interval=$((now - last_ts))
        local new_avg=$(((avg_interval * count + interval) / new_count))
        local tmp="${PREDICTION_DB}.tmp.$$"
        awk -F'|' -v p="$prev" -v c="$curr" '$1 != p || $2 != c' "$PREDICTION_DB" > "$tmp" 2>/dev/null || true
        echo "${prev}|${curr}|${new_count}|${now}|${new_avg}" >> "$tmp"
        mv "$tmp" "$PREDICTION_DB"
    else
        echo "${prev}|${curr}|1|${now}|0" >> "$PREDICTION_DB"
    fi

    # --- time-of-day bucket counts (prev -> curr within this bucket) ---
    local bucket=$(prediction_time_bucket)
    local tmp="${PREDICTION_TIME_DB}.tmp.$$"
    [ -f "$PREDICTION_TIME_DB" ] || touch "$PREDICTION_TIME_DB" 2>/dev/null
    awk -F'|' -v OFS='|' -v p="$prev" -v c="$curr" -v b="$bucket" -v now="$now" '
        $1 == p && $2 == c && $3 == b { $4 += 1; $5 = now; found=1 }
        { print }
        END { if (!found) printf "%s|%s|%s|1|%s\n", p, c, b, now }
    ' "$PREDICTION_TIME_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$PREDICTION_TIME_DB" 2>/dev/null
    prune_prediction_db "$PREDICTION_TIME_DB" 5

    # --- second-order chain (prev2 -> prev -> curr) ---
    if [ -n "$prev2" ] && [ "$prev2" != "$prev" ] && [ "$prev2" != "$curr" ]; then
        local tmp="${PREDICTION2_DB}.tmp.$$"
        [ -f "$PREDICTION2_DB" ] || touch "$PREDICTION2_DB" 2>/dev/null
        awk -F'|' -v OFS='|' -v p2="$prev2" -v p1="$prev" -v n="$curr" -v now="$now" '
            $1 == p2 && $2 == p1 && $3 == n { $4 += 1; $5 = now; found=1 }
            { print }
            END { if (!found) printf "%s|%s|%s|1|%s\n", p2, p1, n, now }
        ' "$PREDICTION2_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$PREDICTION2_DB" 2>/dev/null
        prune_prediction_db "$PREDICTION2_DB" 5
    fi
}

# Predict next app from current app.
# Usage: predict_next_app <curr> [prev_of_curr]
# Two context sources on top of the plain first-order Markov chain:
#   1. TIME:  first-order counts are re-weighted by how often the same
#      transition happened in the CURRENT time-of-day bucket
#      (score = count + time_weight * bucket_count).
#   2. SECOND-ORDER: chains (prev2 -> prev1=curr -> next) capture "what
#      follows this app when I arrived here from THAT app". Used when it has
#      enough samples and is at least as confident as the first-order result.
predict_next_app() {
    local curr=$1
    local prev2=$2
    [ -z "$curr" ] && return
    local enabled=$(read_cfg "$PREDICTION_CONF" "prediction_enabled" "true")
    [ "$enabled" != "true" ] && return

    # ---- first-order, re-weighted by the current time bucket ----
    local bucket=$(prediction_time_bucket)
    local tw=$(read_cfg "$PREDICTION_CONF" "time_weight" "2")
    case "$tw" in ''|*[!0-9]*) tw=2 ;; esac
    local first=$({ awk -F'|' -v curr="$curr" '$1 == curr { print "G|"$2"|"$3 }' \
                        "$PREDICTION_DB" 2>/dev/null
                    awk -F'|' -v curr="$curr" -v b="$bucket" \
                        '$1 == curr && $3 == b { print "T|"$2"|"$4 }' \
                        "$PREDICTION_TIME_DB" 2>/dev/null; } | awk -F'|' -v w="$tw" '
            $1 == "G" { cnt[$2] += $3; tot += $3; next }
            $1 == "T" { tb[$2] += $3; next }
            END {
                for (n in cnt) { s = cnt[n] + w * tb[n]; stot += s;
                                 if (s > bs) { bs = s; bn = n } }
                if (tot >= 3 && stot > 0 && bn != "")
                    printf "%s|%d", bn, int(bs * 100 / stot)
            }')

    # ---- second-order (needs the app we came from) ----
    local second=""
    local so_on=$(read_cfg "$PREDICTION_CONF" "second_order_enabled" "true")
    local so_min=$(read_cfg "$PREDICTION_CONF" "second_order_min_total" "2")
    case "$so_min" in ''|*[!0-9]*) so_min=2 ;; esac
    if [ "$so_on" = "true" ] && [ -n "$prev2" ] && [ -f "$PREDICTION2_DB" ]; then
        second=$(awk -F'|' -v p2="$prev2" -v p1="$curr" -v min="$so_min" '
            $1 == p2 && $2 == p1 { cnt[$3] += $4; tot += $4 }
            END {
                if (tot >= min) {
                    for (n in cnt) if (cnt[n] > bc) { bc = cnt[n]; bn = n }
                    if (bn != "") printf "%s|%d", bn, int(bc * 100 / tot)
                }
            }' "$PREDICTION2_DB" 2>/dev/null)
    fi

    # Prefer second-order when it exists and is at least as confident.
    if [ -n "$second" ]; then
        local s_conf=$(echo "$second" | cut -d'|' -f2)
        local f_conf=$(echo "$first" | cut -d'|' -f2)
        case "$f_conf" in ''|*[!0-9]*) f_conf=0 ;; esac
        if [ -z "$first" ] || [ "$s_conf" -ge "$f_conf" ] 2>/dev/null; then
            echo "$second"
            return
        fi
    fi
    [ -n "$first" ] && echo "$first"
}

check_prediction_limits() {
    local enabled=$(read_cfg "$PREDICTION_CONF" "prediction_enabled" "true")
    [ "$enabled" != "true" ] && return 1

    local temp_limit=$(read_cfg "$PREDICTION_CONF" "temp_limit" "55")
    local battery_limit=$(read_cfg "$PREDICTION_CONF" "battery_limit" "30")
    local cooldown=$(read_cfg "$PREDICTION_CONF" "cooldown_seconds" "5")

    local temp=$(get_temperature)
    local battery=$(get_battery_level)
    local charging=$(get_battery_status)

    [ "$temp" -gt "$temp_limit" ] 2>/dev/null && return 1
    [ "$battery" -lt "$battery_limit" ] 2>/dev/null && [ "$charging" != "Charging" ] && return 1

    local now=$(date +%s)
    local last_pred=$(read_cfg "$PREDICTION_STATE" "last_prediction_ts" "0")
    local elapsed=$((now - last_pred))
    [ "$elapsed" -lt "$cooldown" ] 2>/dev/null && return 1

    # Enforce the hourly prediction budget (was defined in config but never
    # actually checked before)
    local max_per_hour=$(read_cfg "$PREDICTION_CONF" "max_predictions_per_hour" "30")
    local win_start=$(read_cfg "$PREDICTION_STATE" "hour_window_start" "0")
    local hour_count=$(read_cfg "$PREDICTION_STATE" "predictions_this_hour" "0")
    case "$max_per_hour" in ''|*[!0-9]*) max_per_hour=30 ;; esac
    case "$win_start" in ''|*[!0-9]*) win_start=0 ;; esac
    case "$hour_count" in ''|*[!0-9]*) hour_count=0 ;; esac
    if [ $((now - win_start)) -lt 3600 ] && [ "$hour_count" -ge "$max_per_hour" ]; then
        return 1
    fi

    return 0
}

# False-positive circuit breaker.
# v1.5.0 rework - the old version DEADLOCKED: once fp_rate exceeded max_fp
# with >3 predictions, every further prediction was blocked, so the counters
# could never recover; worse, the daily counter reset lived only in
# record_prediction/validate_prediction, which a blocked engine never reaches
# - the lockout was PERMANENT (survived midnight and reboots) until a manual
# database reset. New behavior:
#   1. date-aware: counters from a previous day simply do not count here;
#   2. the breaker arms only after fp_min_predictions samples (default 8,
#      was effectively 4) so small-sample noise cannot trip it;
#   3. tripping engages a TEMPORARY lockout (fp_lockout_minutes, default 30)
#      and resets the counters, so the engine always gets a fresh probation
#      window afterwards instead of a life sentence.
check_false_positive_rate() {
    local max_fp=$(read_cfg "$PREDICTION_CONF" "max_false_positive_rate" "40")
    local min_preds=$(read_cfg "$PREDICTION_CONF" "fp_min_predictions" "8")
    local lock_min=$(read_cfg "$PREDICTION_CONF" "fp_lockout_minutes" "30")
    case "$max_fp" in ''|*[!0-9]*) max_fp=40 ;; esac
    case "$min_preds" in ''|*[!0-9]*) min_preds=8 ;; esac
    case "$lock_min" in ''|*[!0-9]*) lock_min=30 ;; esac

    local now=$(date +%s)

    # Temporary lockout still running?
    local lock_until=$(read_cfg "$PREDICTION_STATE" "fp_lockout_until" "0")
    case "$lock_until" in ''|*[!0-9]*) lock_until=0 ;; esac
    [ "$now" -lt "$lock_until" ] && return 1

    # Date-aware counters: a new day starts from zero even if the state file
    # was never rewritten (which is exactly the old deadlock scenario).
    local today=$(date +%Y-%m-%d)
    local state_date=$(read_cfg "$PREDICTION_STATE" "today_date" "")
    local pred_count=0 fp_count=0
    if [ "$state_date" = "$today" ]; then
        pred_count=$(read_cfg "$PREDICTION_STATE" "predictions_today" "0")
        fp_count=$(read_cfg "$PREDICTION_STATE" "false_positives_today" "0")
        case "$pred_count" in ''|*[!0-9]*) pred_count=0 ;; esac
        case "$fp_count" in ''|*[!0-9]*) fp_count=0 ;; esac
    fi

    [ "$pred_count" -lt "$min_preds" ] 2>/dev/null && return 0  # not armed yet
    local fp_rate=$((fp_count * 100 / pred_count))
    if [ "$fp_rate" -gt "$max_fp" ] 2>/dev/null; then
        # Engage the temporary lockout and reset the probation counters.
        ensure_prediction_state_writable
        local tmp="${PREDICTION_STATE}.tmp.$$"
        grep -vE "^(fp_lockout_until|predictions_today|false_positives_today|today_date)=" "$PREDICTION_STATE" > "$tmp" 2>/dev/null || true
        {
            echo "fp_lockout_until=$((now + lock_min * 60))"
            echo "predictions_today=0"
            echo "false_positives_today=0"
            echo "today_date=$today"
        } >> "$tmp"
        mv "$tmp" "$PREDICTION_STATE" 2>/dev/null
        log_msg "[PREDICT] FP rate ${fp_rate}% > ${max_fp}% over ${pred_count} predictions; pausing predictions for ${lock_min}m (counters reset)"
        return 1
    fi
    return 0
}

# Apply a very mild, restricted boost for predicted next app
apply_prediction_boost() {
    local predicted_pkg=$1
    local confidence=$2
    [ -z "$predicted_pkg" ] && return

    local boost_min=$(read_cfg "$PREDICTION_CONF" "prediction_boost_little_min" "1000000")
    local boost_duration=$(read_cfg "$PREDICTION_CONF" "prediction_boost_duration" "3")

    log_msg "[PREDICT] Predicting next app: $predicted_pkg (confidence: ${confidence}%)"

    # 1. Pre-apply affinity if app is already running in background.
    #    Every bind is verified against the kernel and counted - the old code
    #    logged "Pre-applied" unconditionally while taskset could be failing
    #    behind /dev/null, which is exactly how this used to die silently.
    local predicted_mask=$(get_affinity_mask "$predicted_pkg" "balanced")
    local bg_pids=$(get_app_pids "$predicted_pkg")
    if [ -n "$bg_pids" ]; then
        # A BACKGROUND app almost always sits in a restrictive cpuset group,
        # so the big-core bits of the pre-apply mask are unreachable right
        # now: aff_bind_tid defers those fork-free (and the foreground engine
        # completes them on launch). They are counted apart from failures.
        local pid tid_path tid ok=0 fail=0 deferred=0
        for pid in $bg_pids; do
            [ -d "/proc/$pid/task" ] || continue
            for tid_path in /proc/$pid/task/*; do
                [ -d "$tid_path" ] || continue
                tid=${tid_path##*/}
                case "$tid" in
                    *[!0-9]*) continue ;;
                esac
                if aff_bind_tid "$tid" "$predicted_mask" "PREDICT $predicted_pkg"; then
                    ok=$((ok + 1))
                else
                    case "$AFF_LAST" in
                        defer|clamped) deferred=$((deferred + 1)) ;;
                        dead) ;;
                        *) [ -d "/proc/$tid" ] && fail=$((fail + 1)) ;;
                    esac
                fi
            done
        done
        log_msg "[PREDICT] Pre-applied affinity 0x$predicted_mask for background $predicted_pkg (verified ok=$ok failed=$fail deferred=$deferred-by-cpuset)"
    fi

    # 2. Mild LITTLE core min boost ONLY if current min is lower than boost target
    local curr_little_min=$(cat "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null)
    if [ -n "$curr_little_min" ] && [ "$curr_little_min" -lt "$boost_min" ] 2>/dev/null; then
        echo "$boost_min" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
        log_msg "[PREDICT] Boosted LITTLE min_freq to ${boost_min}"
    fi

    # 3. Enable sched_boost only if currently disabled (temporary, will be overwritten by apply_mode next cycle)
    local curr_boost=$(cat /proc/sys/kernel/sched_boost 2>/dev/null)
    [ "$curr_boost" = "0" ] && echo "1" > /proc/sys/kernel/sched_boost 2>/dev/null

    # 4. Write active prediction: short boost expiry + a LONGER validation
    #    window (field 4). The boost itself ends quickly, but the prediction
    #    must stay pending long enough for the user to actually switch apps,
    #    otherwise true/false positives can never be validated.
    local validation_window=$(read_cfg "$PREDICTION_CONF" "prediction_validation_seconds" "180")
    case "$validation_window" in ''|*[!0-9]*) validation_window=180 ;; esac
    local now_ts=$(date +%s)
    local expiry=$((now_ts + boost_duration))
    local valid_until=$((now_ts + validation_window))
    echo "${expiry}|${predicted_pkg}|${confidence}|${valid_until}" > "$PREDICTION_ACTIVE"

    record_prediction "$predicted_pkg" "$confidence"
}

record_prediction() {
    local pkg=$1
    local confidence=$2
    local now=$(date +%s)
    local today=$(date +%Y-%m-%d)

    ensure_prediction_state_writable

    # Read ALL state values BEFORE rewriting the file. (The old code read them
    # inside a "cat > file <<EOF" heredoc, but the redirect truncates the file
    # before the command substitutions run, silently wiping last_app etc.)
    local pred_count=$(read_cfg "$PREDICTION_STATE" "predictions_today" "0")
    local fp_count=$(read_cfg "$PREDICTION_STATE" "false_positives_today" "0")
    local state_date=$(read_cfg "$PREDICTION_STATE" "today_date" "")
    local win_start=$(read_cfg "$PREDICTION_STATE" "hour_window_start" "0")
    local hour_count=$(read_cfg "$PREDICTION_STATE" "predictions_this_hour" "0")

    case "$pred_count" in ''|*[!0-9]*) pred_count=0 ;; esac
    case "$fp_count" in ''|*[!0-9]*) fp_count=0 ;; esac
    case "$win_start" in ''|*[!0-9]*) win_start=0 ;; esac
    case "$hour_count" in ''|*[!0-9]*) hour_count=0 ;; esac

    if [ "$state_date" != "$today" ]; then
        pred_count=0
        fp_count=0
        state_date=$today
    fi
    if [ $((now - win_start)) -ge 3600 ]; then
        win_start=$now
        hour_count=0
    fi

    pred_count=$((pred_count + 1))
    hour_count=$((hour_count + 1))

    # Rewrite only the keys we own, preserving everything else
    local tmp="${PREDICTION_STATE}.tmp.$$"
    grep -vE "^(predictions_today|false_positives_today|today_date|last_prediction_ts|last_predicted_app|last_predicted_confidence|hour_window_start|predictions_this_hour)=" "$PREDICTION_STATE" > "$tmp" 2>/dev/null || true
    {
        echo "predictions_today=${pred_count}"
        echo "false_positives_today=${fp_count}"
        echo "today_date=${state_date}"
        echo "last_prediction_ts=${now}"
        echo "last_predicted_app=${pkg}"
        echo "last_predicted_confidence=${confidence}"
        echo "hour_window_start=${win_start}"
        echo "predictions_this_hour=${hour_count}"
    } >> "$tmp"
    mv "$tmp" "$PREDICTION_STATE"
}

validate_prediction() {
    local predicted=$1
    local actual=$2
    [ -z "$predicted" ] && return

    ensure_prediction_state_writable
    local today=$(date +%Y-%m-%d)

    local fp_count=$(read_cfg "$PREDICTION_STATE" "false_positives_today" "0")
    local state_date=$(read_cfg "$PREDICTION_STATE" "today_date" "")
    local pred_count=$(read_cfg "$PREDICTION_STATE" "predictions_today" "0")

    if [ "$state_date" != "$today" ]; then
        fp_count=0
        state_date=$today
        pred_count=0
    fi

    if [ "$predicted" != "$actual" ]; then
        fp_count=$((fp_count + 1))
        log_msg "[PREDICT] False positive: predicted $predicted, got $actual"
    else
        log_msg "[PREDICT] True positive: $actual"
    fi

    # Update only FP-related fields, preserving everything else (grep -E is
    # portable; the old BRE "\(...\|...\)" alternation is not).
    local tmp="${PREDICTION_STATE}.tmp.$$"
    grep -vE "^(false_positives_today|today_date|predictions_today)=" "$PREDICTION_STATE" > "$tmp" 2>/dev/null || true
    {
        echo "false_positives_today=${fp_count}"
        echo "today_date=${state_date}"
        echo "predictions_today=${pred_count}"
    } >> "$tmp"
    mv "$tmp" "$PREDICTION_STATE"
}

run_prediction_cycle() {
    local curr_app=$1
    [ -z "$curr_app" ] && return

    local enabled=$(read_cfg "$PREDICTION_CONF" "prediction_enabled" "true")
    [ "$enabled" != "true" ] && return

    local result=$(predict_next_app "$curr_app")
    [ -z "$result" ] && return

    local next_app=$(echo "$result" | cut -d'|' -f1)
    local conf=$(echo "$result" | cut -d'|' -f2)

    [ -z "$next_app" ] || [ -z "$conf" ] && return
    [ "$conf" -lt "$(read_cfg "$PREDICTION_CONF" "confidence_threshold" "60")" ] 2>/dev/null && return

    check_prediction_limits || return
    check_false_positive_rate || return

    apply_prediction_boost "$next_app" "$conf"
}

################################################################################
# MANUAL MODE-SWITCH LEARNING
################################################################################
# Learns the user's per-app mode preference from MANUAL switches only:
#   - CLI "sd730-scheduler --mode X"          (source: user)
#   - Scene calling /data/powercfg.sh X        (source: scene; includes Scene's
#     per-app bindings, which are explicit user configuration)
# The module's OWN auto-applied modes and the thermal/battery guard downgrades
# NEVER touch this database (no feedback loop, no guard pollution).
#
# A learned default is applied at next app launch only when ALL hold:
#   - enough samples: >= min_samples_normal (balanced/performance) or
#     >= min_samples_extreme (powersave/ultra)
#   - the winner's share >= min_share_normal / min_share_extreme
#   - extreme modes additionally cross-check the learned CPU/GPU profile:
#     ultra only for measurably heavy apps, powersave only for light ones
#   - Scene override is "auto" (Scene always wins)

init_mode_learning() {
    ensure_mode_learn_db_writable
    [ ! -f "$MODE_LEARN_DB" ] && touch "$MODE_LEARN_DB"
    if [ ! -f "$MODE_LEARN_CONF" ]; then
        cat > "$MODE_LEARN_CONF" <<'EOF'
mode_learning_enabled=true
auto_apply=true
min_samples_normal=5
min_share_normal=60
min_samples_extreme=8
min_share_extreme=80
profile_min_samples=5
ultra_profile_min=60
powersave_profile_max=50
scene_votes_enabled=true
scene_vote_settle_seconds=8
scene_vote_cooldown_minutes=60
scene_vote_exclude=com.omarea.vtools
learned_overrides_scene=true
EOF
    else
        # Migrate configs written by older versions: append keys they lack.
        grep -q '^scene_votes_enabled='        "$MODE_LEARN_CONF" 2>/dev/null || echo "scene_votes_enabled=true"          >> "$MODE_LEARN_CONF"
        grep -q '^scene_vote_settle_seconds='   "$MODE_LEARN_CONF" 2>/dev/null || echo "scene_vote_settle_seconds=8"      >> "$MODE_LEARN_CONF"
        grep -q '^scene_vote_cooldown_minutes=' "$MODE_LEARN_CONF" 2>/dev/null || echo "scene_vote_cooldown_minutes=60"   >> "$MODE_LEARN_CONF"
        grep -q '^scene_vote_exclude='          "$MODE_LEARN_CONF" 2>/dev/null || echo "scene_vote_exclude=com.omarea.vtools" >> "$MODE_LEARN_CONF"
        grep -q '^learned_overrides_scene='     "$MODE_LEARN_CONF" 2>/dev/null || echo "learned_overrides_scene=true"     >> "$MODE_LEARN_CONF"
    fi
}

# Record one MANUAL mode switch for the foreground app.
# DB line: pkg|powersave|balanced|performance|ultra|last_mode|last_ts|last_source
record_mode_switch() {
    local pkg=$1 mode=$2 source=$3
    [ -z "$pkg" ] && return
    case "$mode" in powersave|balanced|performance|ultra) ;; *) return ;; esac
    [ "$(read_cfg "$MODE_LEARN_CONF" "mode_learning_enabled" "true")" != "true" ] && return
    ensure_mode_learn_db_writable
    [ ! -f "$MODE_LEARN_DB" ] && touch "$MODE_LEARN_DB"

    local line=$(awk -F'|' -v p="$pkg" '$1 == p' "$MODE_LEARN_DB" 2>/dev/null)
    local ps=0 bal=0 perf=0 ultra=0
    if [ -n "$line" ]; then
        ps=$(echo "$line" | cut -d'|' -f2)
        bal=$(echo "$line" | cut -d'|' -f3)
        perf=$(echo "$line" | cut -d'|' -f4)
        ultra=$(echo "$line" | cut -d'|' -f5)
    fi
    local v
    for v in ps bal perf ultra; do
        eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done

    case "$mode" in
        powersave)   ps=$((ps + 1)) ;;
        balanced)    bal=$((bal + 1)) ;;
        performance) perf=$((perf + 1)) ;;
        ultra)       ultra=$((ultra + 1)) ;;
    esac

    local tmp="${MODE_LEARN_DB}.tmp.$$"
    awk -F'|' -v p="$pkg" '$1 != p' "$MODE_LEARN_DB" > "$tmp" 2>/dev/null || true
    echo "${pkg}|${ps}|${bal}|${perf}|${ultra}|${mode}|$(date +%s)|${source}" >> "$tmp"
    mv "$tmp" "$MODE_LEARN_DB"
    log_msg "[MLEARN] Recorded $mode for $pkg (source: $source; ps=$ps bal=$bal perf=$perf ultra=$ultra)"
}

# Gate Scene-sourced votes before recording them.
#
# Scene calls /data/powercfg.sh for BOTH genuine manual toggles AND its own
# automation: per-app bindings (a call every time a bound app enters the
# foreground, plus a revert-to-default call on exit), screen-off / doze and
# energy-adaptation (low-battery) triggers, boot restore and plain
# re-asserts. Counting all of those lets Scene's automation teach the module
# "preferences" the user never expressed (e.g. the launcher ends up with a
# 100% powersave share purely from screen-off events), so a Scene call only
# becomes a vote when it looks like a real manual toggle:
#
#   prev_scene = the scene_mode value in effect BEFORE this call (for the
#                re-assert check); pass "" if unknown.
record_scene_switch() {
    local pkg=$1 mode=$2 prev_scene=$3
    [ -z "$pkg" ] && return
    case "$mode" in powersave|balanced|performance|ultra) ;; *) return ;; esac
    [ "$(read_cfg "$MODE_LEARN_CONF" "mode_learning_enabled" "true")" != "true" ] && return
    [ "$(read_cfg "$MODE_LEARN_CONF" "scene_votes_enabled" "true")" != "true" ] && return

    # Gate 1 - never attribute a vote to Scene itself: toggling the GLOBAL
    # mode inside Scene's own UI is not a preference for the Scene app.
    local exclude=$(read_cfg "$MODE_LEARN_CONF" "scene_vote_exclude" "com.omarea.vtools")
    case " $exclude " in
        *" $pkg "*)
            log_msg "[MLEARN] Ignored scene switch for excluded package $pkg ($mode)"
            return ;;
    esac

    # Gate 2 - screen off/dozing: Scene's screen-off and doze automation is
    # never per-app user intent.
    local wake=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | cut -d= -f2 | tr -d '[:space:]')
    [ -z "$wake" ] && wake=$(dumpsys display 2>/dev/null | grep -m1 'mScreenState=' | cut -d= -f2 | tr -d '[:space:]')
    case "$wake" in
        Asleep|Dozing|OFF|SCREEN_STATE_OFF)
            log_msg "[MLEARN] Ignored scene auto-switch while screen off ($wake): $mode for $pkg"
            return ;;
    esac

    # Gate 3 - foreground transition window: a per-app binding call arrives
    # together with the app entering the foreground (and the revert call
    # arrives with the switch back out); a manual toggle happens while the
    # foreground app has been stable for a while. The state is tracked here
    # (not by the daemon's 3s loop), so the very first call seen for a new
    # foreground app is always classed as a transition. The window slides:
    # every Scene call refreshes it, so automation bursts keep suppressing.
    local settle=$(read_cfg "$MODE_LEARN_CONF" "scene_vote_settle_seconds" "8")
    case "$settle" in ''|*[!0-9]*) settle=8 ;; esac
    local now=$(date +%s)
    local last_pkg="" last_ts=0
    if [ -f "$SCENE_VOTE_STATE" ]; then
        last_pkg=$(cut -d'|' -f1 "$SCENE_VOTE_STATE" 2>/dev/null)
        last_ts=$(cut -d'|' -f2 "$SCENE_VOTE_STATE" 2>/dev/null)
    fi
    case "$last_ts" in ''|*[!0-9]*) last_ts=0 ;; esac
    echo "${pkg}|${now}" > "$SCENE_VOTE_STATE" 2>/dev/null
    if [ "$pkg" != "$last_pkg" ] || [ $((now - last_ts)) -lt "$settle" ]; then
        log_msg "[MLEARN] Ignored scene auto-switch (foreground transition): $mode for $pkg"
        return
    fi

    # Gate 4 - re-assert: Scene re-applying the mode that is already in
    # effect (boot restore, watchdogs, repeated automation) is not a choice.
    if [ -n "$prev_scene" ] && [ "$mode" = "$prev_scene" ]; then
        log_msg "[MLEARN] Ignored scene re-assert ($mode already active) for $pkg"
        return
    fi

    # Gate 5 - same-mode cooldown: even if some automation path slips past
    # the gates above, it can add at most one vote per app per mode per
    # cooldown window, so it can never rush an app past the decision
    # thresholds. A persistent manual preference still accrues over days.
    local cooldown=$(read_cfg "$MODE_LEARN_CONF" "scene_vote_cooldown_minutes" "60")
    case "$cooldown" in ''|*[!0-9]*) cooldown=60 ;; esac
    local line=$(awk -F'|' -v p="$pkg" '$1 == p' "$MODE_LEARN_DB" 2>/dev/null)
    if [ -n "$line" ]; then
        local lmode=$(echo "$line" | cut -d'|' -f6)
        local lts=$(echo "$line" | cut -d'|' -f7)
        case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
        if [ "$lmode" = "$mode" ] && [ $((now - lts)) -lt $((cooldown * 60)) ]; then
            log_msg "[MLEARN] Ignored scene repeat within ${cooldown}m cooldown: $mode for $pkg"
            return
        fi
    fi

    record_mode_switch "$pkg" "$mode" "scene"
}

# Decide the learned default mode for an app.
# Output: "mode|share%|samples" or empty (no confident decision).
mode_learn_decide() {
    local pkg=$1
    [ -z "$pkg" ] && return
    [ "$(read_cfg "$MODE_LEARN_CONF" "mode_learning_enabled" "true")" != "true" ] && return
    local line=$(awk -F'|' -v p="$pkg" '$1 == p' "$MODE_LEARN_DB" 2>/dev/null)
    [ -z "$line" ] && return

    local ps bal perf ultra
    ps=$(echo "$line" | cut -d'|' -f2)
    bal=$(echo "$line" | cut -d'|' -f3)
    perf=$(echo "$line" | cut -d'|' -f4)
    ultra=$(echo "$line" | cut -d'|' -f5)
    local v
    for v in ps bal perf ultra; do
        eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done
    local total=$((ps + bal + perf + ultra))
    [ "$total" -eq 0 ] && return

    # Most-voted mode wins; ties resolve toward the LESS extreme mode.
    local best="balanced" best_n=$bal
    if [ "$perf" -gt "$best_n" ];  then best="performance"; best_n=$perf; fi
    if [ "$ps" -gt "$best_n" ];    then best="powersave";   best_n=$ps; fi
    if [ "$ultra" -gt "$best_n" ]; then best="ultra";       best_n=$ultra; fi
    local share=$((best_n * 100 / total))

    # Dual threshold: extreme modes need MORE samples AND a HIGHER share, so
    # a single impulse switch can never push the next launch to max or min.
    local mins minsh
    case "$best" in
        powersave|ultra)
            mins=$(read_cfg "$MODE_LEARN_CONF" "min_samples_extreme" "8")
            minsh=$(read_cfg "$MODE_LEARN_CONF" "min_share_extreme" "80") ;;
        *)
            mins=$(read_cfg "$MODE_LEARN_CONF" "min_samples_normal" "5")
            minsh=$(read_cfg "$MODE_LEARN_CONF" "min_share_normal" "60") ;;
    esac
    case "$mins" in ''|*[!0-9]*) mins=5 ;; esac
    case "$minsh" in ''|*[!0-9]*) minsh=60 ;; esac
    [ "$total" -lt "$mins" ] 2>/dev/null && return
    [ "$share" -lt "$minsh" ] 2>/dev/null && return

    # Cross-check with the measured CPU/GPU profile (when enough load samples
    # exist): ultra only sticks for heavy apps, powersave only for light ones.
    local pmin=$(read_cfg "$MODE_LEARN_CONF" "profile_min_samples" "5")
    case "$pmin" in ''|*[!0-9]*) pmin=5 ;; esac
    local lline=$(awk -F'|' -v p="$pkg" '$1 == p' "$LEARNING_DB" 2>/dev/null)
    if [ -n "$lline" ]; then
        local lcount=$(echo "$lline" | cut -d'|' -f2)
        case "$lcount" in ''|*[!0-9]*) lcount=0 ;; esac
        if [ "$lcount" -ge "$pmin" ] 2>/dev/null; then
            local probs=$(get_app_probabilities "$pkg")
            local bigp=$(echo "$probs" | cut -d',' -f1)
            local gpup=$(echo "$probs" | cut -d',' -f3)
            case "$bigp" in ''|*[!0-9]*) bigp=50 ;; esac
            case "$gpup" in ''|*[!0-9]*) gpup=30 ;; esac
            case "$best" in
                ultra)
                    local umin=$(read_cfg "$MODE_LEARN_CONF" "ultra_profile_min" "60")
                    case "$umin" in ''|*[!0-9]*) umin=60 ;; esac
                    if [ "$bigp" -lt "$umin" ] && [ "$gpup" -lt "$umin" ] 2>/dev/null; then
                        return   # votes say ultra, but the app is not actually heavy
                    fi ;;
                powersave)
                    local pmax=$(read_cfg "$MODE_LEARN_CONF" "powersave_profile_max" "50")
                    case "$pmax" in ''|*[!0-9]*) pmax=50 ;; esac
                    if [ "$bigp" -gt "$pmax" ] || [ "$gpup" -gt "$pmax" ] 2>/dev/null; then
                        return   # votes say powersave, but the app is actually heavy
                    fi ;;
            esac
        fi
    fi
    echo "${best}|${share}|${total}"
}

get_mode_learning_stats() {
    echo "=== Mode Learning Statistics ==="
    echo "Enabled: $(read_cfg "$MODE_LEARN_CONF" "mode_learning_enabled" "true"), Auto-apply: $(read_cfg "$MODE_LEARN_CONF" "auto_apply" "true")"
    echo "Thresholds: normal >= $(read_cfg "$MODE_LEARN_CONF" "min_samples_normal" "5") samples & $(read_cfg "$MODE_LEARN_CONF" "min_share_normal" "60")% | extreme >= $(read_cfg "$MODE_LEARN_CONF" "min_samples_extreme" "8") samples & $(read_cfg "$MODE_LEARN_CONF" "min_share_extreme" "80")%"
    echo ""
    echo "App | PS | BAL | PERF | ULTRA | Total | BestShare | Decided | LastSource"
    echo "----|----|-----|------|-------|-------|-----------|---------|----------"
    local pkg ps bal perf ultra lm lts lsrc total best best_n share decided
    while IFS='|' read -r pkg ps bal perf ultra lm lts lsrc; do
        for v in ps bal perf ultra; do
            eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
        done
        total=$((ps + bal + perf + ultra))
        best="balanced"; best_n=$bal
        [ "$perf" -gt "$best_n" ]  && { best="performance"; best_n=$perf; }
        [ "$ps" -gt "$best_n" ]    && { best="powersave";   best_n=$ps; }
        [ "$ultra" -gt "$best_n" ] && { best="ultra";       best_n=$ultra; }
        share=0
        [ "$total" -gt 0 ] && share=$((best_n * 100 / total))
        decided=$(mode_learn_decide "$pkg" | cut -d'|' -f1)
        [ -z "$decided" ] && decided="-"
        printf "%-24s | %2s | %3s | %4s | %5s | %5s | %7s%% | %-11s | %s\n" \
            "$pkg" "$ps" "$bal" "$perf" "$ultra" "$total" "$share" "$decided" "$lsrc"
    done < "$MODE_LEARN_DB" 2>/dev/null
    if [ -f "$MODE_LEARN_STATE" ]; then
        echo ""
        echo "Active auto-applied: $(cat "$MODE_LEARN_STATE" 2>/dev/null)"
    fi
}

reset_mode_learning() {
    ensure_mode_learn_db_writable
    > "$MODE_LEARN_DB"
    rm -f "$MODE_LEARN_STATE"
    echo "[+] Mode learning database reset."
}

################################################################################
# MODE APPLICATION
################################################################################

init_scheduler() {
    mkdir -p "$CONFIG_DIR"
    init_learning_db
    init_prediction
    init_mode_learning
    [ ! -f "$CONFIG_DIR/current_mode" ] && echo "balanced" > "$CONFIG_DIR/current_mode"
    [ ! -f "$CONFIG_DIR/scene_mode" ] && echo "auto" > "$CONFIG_DIR/scene_mode"
    for cpu in $ALL_CORES; do
        echo "schedutil" > "$CPU_BASE/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null
    done
    echo "msm-adreno-tz" > "$GPU_GOVERNOR" 2>/dev/null
}

# Expected big-cluster max freq for a mode (from modes.conf, else built-in).
# Used as a cheap "sentinel" to detect external actors overriding our settings.
expected_big_max() {
    local line=""
    [ -f "$CONFIG_DIR/modes.conf" ] && line=$(awk -F'|' -v m="$1" '$1 == m {print; exit}' "$CONFIG_DIR/modes.conf" 2>/dev/null)
    if [ -n "$line" ]; then
        local v=$(echo "$line" | cut -d'|' -f5)
        case "$v" in ''|*[!0-9]*) v="" ;; esac
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    case "$1" in
        powersave) echo "1324800" ;;
        *) echo "2208000" ;;
    esac
}

# Apply a mode's frequencies. config/modes.conf is the live source of truth;
# the built-in apply_* profiles are the fallback for missing/invalid entries.
apply_mode_freqs() {
    local mode=$1
    local line=""
    [ -f "$CONFIG_DIR/modes.conf" ] && line=$(awk -F'|' -v m="$mode" '$1 == m {print; exit}' "$CONFIG_DIR/modes.conf" 2>/dev/null)
    if [ -n "$line" ]; then
        local lmin=$(echo "$line" | cut -d'|' -f2)
        local lmax=$(echo "$line" | cut -d'|' -f3)
        local bmin=$(echo "$line" | cut -d'|' -f4)
        local bmax=$(echo "$line" | cut -d'|' -f5)
        local gmin=$(echo "$line" | cut -d'|' -f6)
        local gmax=$(echo "$line" | cut -d'|' -f7)
        local boost=$(echo "$line" | cut -d'|' -f8)
        local ok=1
        local v
        for v in "$lmin" "$lmax" "$bmin" "$bmax" "$gmin" "$gmax" "$boost"; do
            case "$v" in ''|*[!0-9]*) ok=0 ;; esac
        done
        if [ "$ok" = "1" ]; then
            echo "$lmin" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
            echo "$lmax" > "$CPU_BASE/cpufreq/policy0/scaling_max_freq" 2>/dev/null
            echo "$bmin" > "$CPU_BASE/cpufreq/policy6/scaling_min_freq" 2>/dev/null
            echo "$bmax" > "$CPU_BASE/cpufreq/policy6/scaling_max_freq" 2>/dev/null
            if [ "$mode" = "ultra" ]; then
                echo "performance" > "$CPU_BASE/cpufreq/policy0/scaling_governor" 2>/dev/null
                echo "performance" > "$CPU_BASE/cpufreq/policy6/scaling_governor" 2>/dev/null
                gpu_ultra_lock "$gmin" "$gmax"
            else
                echo "schedutil" > "$CPU_BASE/cpufreq/policy0/scaling_governor" 2>/dev/null
                echo "schedutil" > "$CPU_BASE/cpufreq/policy6/scaling_governor" 2>/dev/null
                gpu_ultra_unlock "mode $mode"
                apply_gpu_limits "$gmin" "$gmax"
            fi
            echo "$boost" > /proc/sys/kernel/sched_boost 2>/dev/null
            return
        fi
        log_msg "[WARN] modes.conf entry for '$mode' is invalid, using built-in profile"
    fi
    case "$mode" in
        powersave) apply_powersave ;;
        balanced) apply_balanced ;;
        performance) apply_performance ;;
        ultra) apply_ultra ;;
        *) apply_balanced ;;
    esac
}

# Usage: apply_mode <mode> [foreground_app] [force]
apply_mode() {
    local mode=$1
    local fg_app=$2
    local force=$3
    local temp=$(get_temperature)
    local battery=$(get_battery_level)
    local charging=$(get_battery_status)

    # Thermal guard
    if [ "$temp" -gt 75 ] 2>/dev/null && [ "$mode" = "ultra" ]; then
        log_msg "[GUARD] Temp ${temp}C > 75C, downgrading ultra -> performance"
        mode="performance"
    elif [ "$temp" -gt 85 ] 2>/dev/null && [ "$mode" = "performance" ]; then
        log_msg "[GUARD] Temp ${temp}C > 85C, downgrading performance -> balanced"
        mode="balanced"
    fi

    # Battery guard
    if [ "$battery" -lt 15 ] 2>/dev/null && [ "$charging" != "Charging" ]; then
        if [ "$mode" = "ultra" ] || [ "$mode" = "performance" ]; then
            log_msg "[GUARD] Battery ${battery}% < 15%, downgrading ${mode} -> balanced"
            mode="balanced"
        fi
    fi

    # Validate mode: garbage (e.g. written into scene_mode) falls back safely
    case "$mode" in
        powersave|balanced|performance|ultra) ;;
        *) mode="balanced" ;;
    esac

    # Skip the sysfs rewrite when the effective mode is unchanged, BUT verify
    # a sentinel value so an external actor (thermal daemon, other schedulers)
    # that overrode us gets corrected. Also makes modes.conf edits live.
    local need_apply=1
    local last_mode=$(cat "$CONFIG_DIR/.last_mode" 2>/dev/null)
    if [ "$mode" = "$last_mode" ] && [ "$force" != "force" ]; then
        need_apply=0
        local want_bmax=$(expected_big_max "$mode")
        local cur_bmax=$(cat "$CPU_BASE/cpufreq/policy6/scaling_max_freq" 2>/dev/null)
        if [ -n "$want_bmax" ] && [ -n "$cur_bmax" ] && [ "$cur_bmax" != "$want_bmax" ]; then
            need_apply=1
        fi
    fi
    if [ "$need_apply" = "1" ]; then
        # Publish the mode BEFORE touching sysfs: the GPU watchdog keys off
        # .last_mode, and the old order (sysfs first, marker second) left a
        # full watchdog-cycle window in which the watchdog still saw the OLD
        # mode and re-asserted the OLD GPU limits (e.g. the ultra 700MHz
        # lock) on top of the NEW mode's values we had just written.
        echo "$mode" > "$CONFIG_DIR/.last_mode"
        apply_mode_freqs "$mode"
    fi

    # Re-apply prediction boost while the boost window is open; keep the state
    # file around until the LONGER validation window closes (so the pending
    # prediction in service.sh can still be validated).
    if [ -f "$PREDICTION_ACTIVE" ]; then
        local expiry=$(cut -d'|' -f1 "$PREDICTION_ACTIVE" 2>/dev/null)
        local valid_until=$(cut -d'|' -f4 "$PREDICTION_ACTIVE" 2>/dev/null)
        local now=$(date +%s)
        case "$expiry" in ''|*[!0-9]*) expiry=0 ;; esac
        case "$valid_until" in ''|*[!0-9]*) valid_until=$expiry ;; esac
        if [ "$now" -lt "$expiry" ]; then
            local boost_min=$(read_cfg "$PREDICTION_CONF" "prediction_boost_little_min" "1000000")
            local curr_little_min=$(cat "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null)
            if [ -n "$curr_little_min" ] && [ "$curr_little_min" -lt "$boost_min" ] 2>/dev/null; then
                echo "$boost_min" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
            fi
        elif [ "$now" -ge "$valid_until" ]; then
            rm -f "$PREDICTION_ACTIVE"
        fi
    fi

    [ -z "$fg_app" ] && fg_app=$(get_foreground_app)
    [ -n "$fg_app" ] && apply_app_affinity "$fg_app" "$mode"
}

# Highest GPU frequency in the device OPP table (the real hardware ceiling).
gpu_table_max() {
    local freqs=$(cat "$GPU_PATH/devfreq/available_frequencies" 2>/dev/null)
    local max=0 f
    for f in $freqs; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        [ "$f" -gt "$max" ] && max=$f
    done
    # Table unreadable: assume the full SD730G ceiling (825MHz)
    [ "$max" -eq 0 ] && max=825000000
    echo "$max"
}

# Soft GPU limit apply: modes.conf may ask for the full 825MHz, but some
# vendors ship a clipped OPP table (e.g. a 730G tablet whose table stops at
# 700MHz). We try the requested value, verify against the table, and fall
# back to the highest real step. (Out-of-table writes would be clamped by
# devfreq anyway; pre-clamping keeps the logs and status output truthful.)
apply_gpu_limits() {
    local req_min=$1 req_max=$2
    case "$req_min" in ''|*[!0-9]*) req_min=0 ;; esac
    case "$req_max" in ''|*[!0-9]*) req_max=825000000 ;; esac
    local tmax=$(gpu_table_max)
    local eff_min=$req_min eff_max=$req_max
    if [ "$req_max" -gt "$tmax" ] 2>/dev/null; then
        eff_max=$tmax
        log_msg "[GPU] Requested max ${req_max}Hz exceeds device OPP table, soft fallback to ${tmax}Hz"
    fi
    [ "$eff_min" -gt "$eff_max" ] 2>/dev/null && eff_min=$eff_max
    echo "$eff_min" > "$GPU_MIN" 2>/dev/null
    echo "$eff_max" > "$GPU_MAX" 2>/dev/null
}

################################################################################
# GPU ULTRA HARD-LOCK
#
# Why this exists: plain "min_freq=max_freq" writes do NOT survive a game
# session. The thermal engine (or a vendor perf daemon) later rewrites
# devfreq max_freq and/or kgsl max_pwrlevel - when the ceiling is clamped to
# the lowest OPP step (180MHz) the kernel silently clamps min down to it too,
# and the GPU is stuck at 180MHz until the next mode application. The plain
# mode sentinel only watches CPU policy6, so the GPU drift was never even
# detected, let alone corrected.
#
# Lock strategy (all shell-level sysfs writes, layered so a single ignored
# node cannot drop the clock):
#   1. devfreq min_freq = max_freq = target   (the primary clamp)
#   2. devfreq governor = performance         (devfreq itself pins max_freq)
#   3. kgsl max_pwrlevel = min_pwrlevel = 0   (pwrlevel 0 = fastest; thermal
#      throttling on Adreno works by RAISING max_pwrlevel - nail it to 0)
#   4. kgsl force_clk_on/force_bus_on/force_rail_on = 1 (no clock gating)
# Plus a 1s watchdog that reads every node back and re-asserts on drift.
#
# The lock engages ONLY in ultra mode AND only when the configured ultra
# gpu_min >= gpu_max (i.e. the config asks for a single pinned frequency).
# The target is min(device OPP table max, configured max): on a table clipped
# at 700MHz the stock "825|825" entry locks at 700MHz. Edit modes.conf's
# ultra line to "0|825000000" (min<max) to disable the lock entirely.
################################################################################

# Prints the lock target in Hz, or nothing when the lock is not configured.
gpu_ultra_target() {
    local line="" req_min="" req_max=""
    [ -f "$CONFIG_DIR/modes.conf" ] && line=$(awk -F'|' -v m="ultra" '$1 == m {print; exit}' "$CONFIG_DIR/modes.conf" 2>/dev/null)
    if [ -n "$line" ]; then
        req_min=$(echo "$line" | cut -d'|' -f6)
        req_max=$(echo "$line" | cut -d'|' -f7)
    fi
    case "$req_min" in ''|*[!0-9]*) req_min=825000000 ;; esac
    case "$req_max" in ''|*[!0-9]*) req_max=825000000 ;; esac
    # Lock semantics: the request asks to pin a single frequency (min>=max).
    [ "$req_min" -lt "$req_max" ] 2>/dev/null && return 1
    local tmax=$(gpu_table_max)
    local target=$req_max
    [ "$target" -gt "$tmax" ] 2>/dev/null && target=$tmax
    case "$target" in ''|*[!0-9]*) return 1 ;; esac
    [ "$target" -le 0 ] 2>/dev/null && return 1
    echo "$target"
}

# Pure write pass (also used by the watchdog repair path). Order matters:
# raise the devfreq ceiling BEFORE the floor (a min>max write is clamped to
# the old max), and drop max_pwrlevel BEFORE min_pwrlevel (the kernel
# requires max_pwrlevel <= min_pwrlevel numerically).
gpu_ultra_lock_apply() {
    local target=$1
    echo "$target" > "$GPU_MAX" 2>/dev/null
    echo "$target" > "$GPU_MIN" 2>/dev/null
    [ -f "$GPU_PATH/max_pwrlevel" ] && echo "0" > "$GPU_PATH/max_pwrlevel" 2>/dev/null
    [ -f "$GPU_PATH/min_pwrlevel" ] && echo "0" > "$GPU_PATH/min_pwrlevel" 2>/dev/null
    [ -f "$GPU_PATH/force_clk_on" ]  && echo "1" > "$GPU_PATH/force_clk_on" 2>/dev/null
    [ -f "$GPU_PATH/force_bus_on" ]  && echo "1" > "$GPU_PATH/force_bus_on" 2>/dev/null
    [ -f "$GPU_PATH/force_rail_on" ] && echo "1" > "$GPU_PATH/force_rail_on" 2>/dev/null
    echo "performance" > "$GPU_GOVERNOR" 2>/dev/null
}

# Engage the lock for ultra mode. Falls back to plain soft limits when the
# config does not request a pinned frequency (min<max).
gpu_ultra_lock() {
    local target=$(gpu_ultra_target)
    if [ -z "$target" ]; then
        gpu_ultra_unlock "lock not configured"
        apply_gpu_limits "$1" "$2"
        return
    fi
    gpu_ultra_lock_apply "$target"
    echo "${target}|${target}|locked" > "$GPU_LOCK_STATE" 2>/dev/null
    log_msg "[GPU][LOCK] ultra hard-lock engaged at $((target / 1000000))MHz (devfreq min/max + performance governor + pwrlevel0 + force_clk/bus/rail; write-first watchdog)"
}

# Release the lock (idempotent; the state file short-circuits repeat calls).
gpu_ultra_unlock() {
    [ -f "$GPU_LOCK_STATE" ] || return 0
    local npl=$(cat "$GPU_PATH/num_pwrlevels" 2>/dev/null)
    case "$npl" in ''|*[!0-9]*) npl=0 ;; esac
    echo "msm-adreno-tz" > "$GPU_GOVERNOR" 2>/dev/null
    [ -f "$GPU_PATH/max_pwrlevel" ] && echo "0" > "$GPU_PATH/max_pwrlevel" 2>/dev/null
    [ "$npl" -gt 0 ] 2>/dev/null && [ -f "$GPU_PATH/min_pwrlevel" ] && \
        echo "$((npl - 1))" > "$GPU_PATH/min_pwrlevel" 2>/dev/null
    [ -f "$GPU_PATH/force_clk_on" ]  && echo "0" > "$GPU_PATH/force_clk_on" 2>/dev/null
    [ -f "$GPU_PATH/force_bus_on" ]  && echo "0" > "$GPU_PATH/force_bus_on" 2>/dev/null
    [ -f "$GPU_PATH/force_rail_on" ] && echo "0" > "$GPU_PATH/force_rail_on" 2>/dev/null
    rm -f "$GPU_LOCK_STATE" 2>/dev/null
    log_msg "[GPU][LOCK] ultra hard-lock released ($1)"
}

# Watchdog repair pass: verify every locked node against the kernel and
# re-assert the full stack on any drift. Log throttled to one line per 10s.
GPULOCK_LAST_LOG=0
gpu_ultra_verify() {
    local target=$(gpu_ultra_target)
    if [ -z "$target" ]; then
        [ -f "$GPU_LOCK_STATE" ] && gpu_ultra_unlock "lock no longer configured"
        return
    fi
    local drift="" v
    v=$(cat "$GPU_MAX" 2>/dev/null); [ "$v" != "$target" ] && drift="${drift}max=$v "
    v=$(cat "$GPU_MIN" 2>/dev/null); [ "$v" != "$target" ] && drift="${drift}min=$v "
    v=$(cat "$GPU_GOVERNOR" 2>/dev/null); [ "$v" != "performance" ] && drift="${drift}gov=$v "
    v=$(cat "$GPU_PATH/max_pwrlevel" 2>/dev/null); [ -n "$v" ] && [ "$v" != "0" ] && drift="${drift}maxpl=$v "
    v=$(cat "$GPU_PATH/min_pwrlevel" 2>/dev/null); [ -n "$v" ] && [ "$v" != "0" ] && drift="${drift}minpl=$v "
    v=$(cat "$GPU_PATH/force_clk_on" 2>/dev/null); [ -n "$v" ] && [ "$v" != "1" ] && drift="${drift}clk=$v "
    [ -z "$drift" ] && return 0
    gpu_ultra_lock_apply "$target"
    echo "${target}|${target}|locked" > "$GPU_LOCK_STATE" 2>/dev/null
    local now=$(date +%s)
    case "$GPULOCK_LAST_LOG" in ''|*[!0-9]*) GPULOCK_LAST_LOG=0 ;; esac
    if [ $((now - GPULOCK_LAST_LOG)) -ge 10 ] 2>/dev/null; then
        local tpl=$(cat "$GPU_PATH/thermal_pwrlevel" 2>/dev/null)
        log_msg "[GPU][LOCK] re-asserted $((target / 1000000))MHz (drift: ${drift}thermal_pl=${tpl:-n/a})"
        GPULOCK_LAST_LOG=$now
    fi
}

################################################################################
# GPU ADAPTIVE LOCK (v1.5.4)
#
# Two upgrades over the plain detect-then-write watchdog:
#
# 1. WRITE-FIRST: every watchdog cycle (lock_write_interval, may be < 1s) the
#    whole ultra lock stack is rewritten UNCONDITIONALLY and only THEN read
#    back for verification/logging. The old verify-then-write order always
#    lost up to one full interval between "thermal engine clamps the GPU" and
#    "we notice"; write-first shrinks the recovery gap to the write itself.
#
# 2. ADAPTIVE FLOOR: ultra may let the GPU breathe inside a bounded band
#    [ultra_floor_hz, OPP-table-max] instead of pinning it flat. The CEILING
#    never moves (max_freq stays at the table top, max_pwrlevel stays 0);
#    only the floor does. Whether relaxing is allowed right now is decided
#    from the Thread Pin Engine's live sampling (TPIN_STATE): a foreground
#    thread at/above important_thread_cpu % of one core means an IMPORTANT
#    scene (game loop running) -> instant re-lock on the next cycle. After
#    relax_after_cycles consecutive quiet cycles the floor drops to
#    ultra_floor_hz and the governor returns to msm-adreno-tz, so genuinely
#    thermally-limited sessions can wander inside the band instead of
#    bouncing off a hard-pinned clock. The learned per-app GPU tier modulates
#    eagerness: heavy-profile apps relax slower (2x cycles), light ones
#    faster (half). No/stale thread data => treated as important (stay
#    locked): when in doubt the clock stays up.
################################################################################

# GPU adaptive scheduler defaults (mirrored in config/gpu_sched.conf and
# customize.sh). GPU_S_INTERVAL is a sleep argument string ("1" or "0.5").
GPU_S_ENABLED="true"
GPU_S_INTERVAL="1"
GPU_S_FLOOR=565000000
GPU_S_IMPORTANT_CPU=25
GPU_S_RELAX_CYCLES=5
GPU_S_MIN_SAMPLES=5
GPU_S_HEAVY_PCT=70
GPU_S_MID_PCT=40
GPU_S_HEAVY_MIN=430000000
GPU_S_HEAVY_MAX=0
GPU_S_MID_MIN=267000000
GPU_S_MID_MAX=650000000
GPU_S_LIGHT_MIN=0
GPU_S_LIGHT_MAX=565000000
GPU_S_FLOOR_EFF=0        # OPP-snapped floor, recomputed on conf (re)load

# Load gpu_sched.conf into the GPU_S_* globals in ONE read pass (fork-free),
# same pattern as tpin_load_conf. Both the main loop and the (separately
# forked) watchdog call this, each keeping its own copy of the values.
gpu_sched_load_conf() {
    GPU_S_ENABLED="true"; GPU_S_INTERVAL="1"; GPU_S_FLOOR=565000000
    GPU_S_IMPORTANT_CPU=25; GPU_S_RELAX_CYCLES=5; GPU_S_MIN_SAMPLES=5
    GPU_S_HEAVY_PCT=70; GPU_S_MID_PCT=40
    GPU_S_HEAVY_MIN=430000000; GPU_S_HEAVY_MAX=0
    GPU_S_MID_MIN=267000000; GPU_S_MID_MAX=650000000
    GPU_S_LIGHT_MIN=0; GPU_S_LIGHT_MAX=565000000
    if [ -f "$GPU_SCHED_CONF" ]; then
        local k v
        while IFS='=' read -r k v; do
            case "$v" in *$'\r') v=${v%$'\r'} ;; esac
            case "$k" in
                ''|\#*) continue ;;
                gpu_sched_enabled) GPU_S_ENABLED=$v ;;
                lock_write_interval) GPU_S_INTERVAL=$v ;;
                ultra_floor_hz) GPU_S_FLOOR=$v ;;
                important_thread_cpu) GPU_S_IMPORTANT_CPU=$v ;;
                relax_after_cycles) GPU_S_RELAX_CYCLES=$v ;;
                profile_min_samples) GPU_S_MIN_SAMPLES=$v ;;
                heavy_gpu_pct) GPU_S_HEAVY_PCT=$v ;;
                mid_gpu_pct) GPU_S_MID_PCT=$v ;;
                heavy_min_hz) GPU_S_HEAVY_MIN=$v ;;
                heavy_max_hz) GPU_S_HEAVY_MAX=$v ;;
                mid_min_hz) GPU_S_MID_MIN=$v ;;
                mid_max_hz) GPU_S_MID_MAX=$v ;;
                light_min_hz) GPU_S_LIGHT_MIN=$v ;;
                light_max_hz) GPU_S_LIGHT_MAX=$v ;;
            esac
        done < "$GPU_SCHED_CONF"
    fi
    # Numeric sanitation: garbage falls back to the defaults.
    case "$GPU_S_ENABLED" in true|false) ;; *) GPU_S_ENABLED="true" ;; esac
    case "$GPU_S_INTERVAL" in ''|*[!0-9.]*) GPU_S_INTERVAL="1" ;; esac
    # Normalize edge spellings so any sleep parser takes them: ".5" -> "0.5",
    # "1." -> "1"; an all-zero interval (0 / 0.0 / 0.00...) would busy-loop.
    case "$GPU_S_INTERVAL" in .*) GPU_S_INTERVAL="0${GPU_S_INTERVAL}" ;; esac
    case "$GPU_S_INTERVAL" in *.) GPU_S_INTERVAL="${GPU_S_INTERVAL%.}" ;; esac
    case "$GPU_S_INTERVAL" in 0|0.*[!0.]*) ;; 0.*) GPU_S_INTERVAL="1" ;; esac
    [ "$GPU_S_INTERVAL" = "0" ] && GPU_S_INTERVAL="1"
    case "$GPU_S_FLOOR" in ''|*[!0-9]*) GPU_S_FLOOR=565000000 ;; esac
    case "$GPU_S_IMPORTANT_CPU" in ''|*[!0-9]*) GPU_S_IMPORTANT_CPU=25 ;; esac
    case "$GPU_S_RELAX_CYCLES" in ''|*[!0-9]*) GPU_S_RELAX_CYCLES=5 ;; esac
    [ "$GPU_S_RELAX_CYCLES" -lt 1 ] 2>/dev/null && GPU_S_RELAX_CYCLES=1
    case "$GPU_S_MIN_SAMPLES" in ''|*[!0-9]*) GPU_S_MIN_SAMPLES=5 ;; esac
    case "$GPU_S_HEAVY_PCT" in ''|*[!0-9]*) GPU_S_HEAVY_PCT=70 ;; esac
    case "$GPU_S_MID_PCT" in ''|*[!0-9]*) GPU_S_MID_PCT=40 ;; esac
    [ "$GPU_S_MID_PCT" -gt "$GPU_S_HEAVY_PCT" ] 2>/dev/null && GPU_S_MID_PCT=$GPU_S_HEAVY_PCT
    case "$GPU_S_HEAVY_MIN" in ''|*[!0-9]*) GPU_S_HEAVY_MIN=430000000 ;; esac
    case "$GPU_S_HEAVY_MAX" in ''|*[!0-9]*) GPU_S_HEAVY_MAX=0 ;; esac
    case "$GPU_S_MID_MIN" in ''|*[!0-9]*) GPU_S_MID_MIN=267000000 ;; esac
    case "$GPU_S_MID_MAX" in ''|*[!0-9]*) GPU_S_MID_MAX=650000000 ;; esac
    case "$GPU_S_LIGHT_MIN" in ''|*[!0-9]*) GPU_S_LIGHT_MIN=0 ;; esac
    case "$GPU_S_LIGHT_MAX" in ''|*[!0-9]*) GPU_S_LIGHT_MAX=565000000 ;; esac
    # Cache the OPP-snapped ultra floor once per (re)load: the watchdog would
    # otherwise re-read available_frequencies every sub-second cycle.
    GPU_S_FLOOR_EFF=$(gpu_snap_freq "$GPU_S_FLOOR")
}

# Snap an arbitrary Hz value to the closest step the device OPP table really
# contains. devfreq would clamp out-of-table writes anyway; pre-snapping keeps
# logs and state files truthful.
gpu_snap_freq() {
    local want=$1
    case "$want" in ''|*[!0-9]*) echo "0"; return ;; esac
    local freqs=$(cat "$GPU_PATH/devfreq/available_frequencies" 2>/dev/null)
    [ -z "$freqs" ] && { echo "$want"; return; }
    local best="" f diff bestdiff=0
    for f in $freqs; do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        diff=$((f - want)); [ "$diff" -lt 0 ] && diff=$((-diff))
        if [ -z "$best" ] || [ "$diff" -lt "$bestdiff" ]; then
            best=$f; bestdiff=$diff
        fi
    done
    [ -z "$best" ] && best=$want
    echo "$best"
}

# Important-scene verdict from the Thread Pin Engine's live state (fork-free
# tmpfs read). Returns 0 (important => stay fully locked) when:
#   - any sampled thread of the foreground app is at/above
#     important_thread_cpu % of one core, OR
#   - there is no trustworthy data (no state file, no TID rows yet, or the
#     newest sample is stale): when in doubt the clock stays UP.
# Returns 1 only on a fresh, genuinely quiet sample set.
gpu_scene_important() {
    [ -f "$TPIN_STATE" ] || return 0
    local now=$(date +%s)
    local tag f2 f3 f4 f5 f6 f7 rest ts=0 n_tid=0
    while IFS='|' read -r tag f2 f3 f4 f5 f6 f7 rest; do
        [ "$tag" = "TID" ] || continue
        n_tid=$((n_tid + 1))
        case "$f6" in ''|*[!0-9]*) f6=0 ;; esac
        [ "$f6" -gt "$ts" ] && ts=$f6
        case "$f7" in ''|*[!0-9]*) continue ;; esac
        [ "$f7" -ge "$GPU_S_IMPORTANT_CPU" ] 2>/dev/null && return 0
    done < "$TPIN_STATE"
    [ "$n_tid" -eq 0 ] && return 0
    [ "$ts" -gt 0 ] && [ $((now - ts)) -gt 10 ] 2>/dev/null && return 0
    return 1
}

# Pure write pass for the adaptive lock. locked=1 pins min=max=target with
# the performance governor, pwrlevel 0/0 and force_* on; locked=0 keeps the
# ceiling nailed (max=target, max_pwrlevel=0 - the top NEVER moves) but drops
# the floor to `floor` and hands control back to msm-adreno-tz so the clock
# can wander inside [floor, target]. Write order is constraint-safe in both
# directions: devfreq ceiling before floor, max_pwrlevel before min_pwrlevel.
gpu_ultra_write_stack() {
    local target=$1 floor=$2 locked=$3
    echo "$target" > "$GPU_MAX" 2>/dev/null
    if [ "$locked" = "1" ]; then
        echo "$target" > "$GPU_MIN" 2>/dev/null
        [ -f "$GPU_PATH/max_pwrlevel" ] && echo "0" > "$GPU_PATH/max_pwrlevel" 2>/dev/null
        [ -f "$GPU_PATH/min_pwrlevel" ] && echo "0" > "$GPU_PATH/min_pwrlevel" 2>/dev/null
        [ -f "$GPU_PATH/force_clk_on" ]  && echo "1" > "$GPU_PATH/force_clk_on" 2>/dev/null
        [ -f "$GPU_PATH/force_bus_on" ]  && echo "1" > "$GPU_PATH/force_bus_on" 2>/dev/null
        [ -f "$GPU_PATH/force_rail_on" ] && echo "1" > "$GPU_PATH/force_rail_on" 2>/dev/null
        echo "performance" > "$GPU_GOVERNOR" 2>/dev/null
    else
        echo "$floor" > "$GPU_MIN" 2>/dev/null
        [ -f "$GPU_PATH/max_pwrlevel" ] && echo "0" > "$GPU_PATH/max_pwrlevel" 2>/dev/null
        local npl=$(cat "$GPU_PATH/num_pwrlevels" 2>/dev/null)
        case "$npl" in ''|*[!0-9]*) npl=0 ;; esac
        [ "$npl" -gt 0 ] 2>/dev/null && [ -f "$GPU_PATH/min_pwrlevel" ] && \
            echo "$((npl - 1))" > "$GPU_PATH/min_pwrlevel" 2>/dev/null
        [ -f "$GPU_PATH/force_clk_on" ]  && echo "0" > "$GPU_PATH/force_clk_on" 2>/dev/null
        [ -f "$GPU_PATH/force_bus_on" ]  && echo "0" > "$GPU_PATH/force_bus_on" 2>/dev/null
        [ -f "$GPU_PATH/force_rail_on" ] && echo "0" > "$GPU_PATH/force_rail_on" 2>/dev/null
        echo "msm-adreno-tz" > "$GPU_GOVERNOR" 2>/dev/null
    fi
}

# Watchdog hot path (ultra only): decide locked/relaxed, WRITE FIRST, then
# verify. State lives in watchdog-process globals: the relax counter resets
# the instant a hot thread shows up, so re-locking never waits; relaxing
# needs relax_after_cycles consecutive quiet cycles (hysteresis, no flapping).
GPU_ULTRA_RELAX_CNT=0
GPU_ULTRA_LAST_STATE=""
GPUADAPT_LAST_LOG=0
gpu_ultra_maintain() {
    local target=$(gpu_ultra_target)
    if [ -z "$target" ]; then
        [ -f "$GPU_LOCK_STATE" ] && gpu_ultra_unlock "lock no longer configured"
        GPU_ULTRA_RELAX_CNT=0; GPU_ULTRA_LAST_STATE=""
        return
    fi
    local floor=$GPU_S_FLOOR_EFF
    case "$floor" in ''|*[!0-9]*) floor=$target ;; esac
    [ "$floor" -le 0 ] 2>/dev/null && floor=$target
    [ "$floor" -gt "$target" ] 2>/dev/null && floor=$target

    # Learned per-app GPU tier (published by the main loop) modulates how
    # quickly relaxing is allowed: heavy profiles stay pinned longer, light
    # ones breathe sooner. Unknown tier uses the configured default.
    local st_pkg="" st_mode="" st_tier="" st_rest=""
    [ -f "$GPU_APP_STATE" ] && IFS='|' read -r st_pkg st_mode st_tier st_rest < "$GPU_APP_STATE" 2>/dev/null
    local relax_need=$GPU_S_RELAX_CYCLES
    case "$st_tier" in
        heavy) relax_need=$((GPU_S_RELAX_CYCLES * 2)) ;;
        light) relax_need=$(( (GPU_S_RELAX_CYCLES + 1) / 2 )) ;;
    esac
    [ "$relax_need" -lt 1 ] && relax_need=1

    if gpu_scene_important; then
        GPU_ULTRA_RELAX_CNT=0
    else
        GPU_ULTRA_RELAX_CNT=$((GPU_ULTRA_RELAX_CNT + 1))
    fi
    local locked=1
    [ "$GPU_ULTRA_RELAX_CNT" -ge "$relax_need" ] && locked=0
    [ "$floor" -ge "$target" ] && locked=1     # no band to breathe in

    local want_min=$target state="locked"
    if [ "$locked" = "0" ]; then
        want_min=$floor; state="relaxed"
    fi

    # WRITE FIRST: the full stack, unconditionally, every single cycle.
    gpu_ultra_write_stack "$target" "$want_min" "$locked"
    echo "${target}|${want_min}|${state}" > "$GPU_LOCK_STATE" 2>/dev/null

    if [ "$state" != "$GPU_ULTRA_LAST_STATE" ]; then
        if [ "$state" = "relaxed" ]; then
            log_msg "[GPU][ADAPT] ultra relaxed -> floor $((want_min / 1000000))MHz, cap stays $((target / 1000000))MHz (quiet for ${GPU_ULTRA_RELAX_CNT} cycles, tier=${st_tier:-n/a})"
        elif [ "$GPU_ULTRA_LAST_STATE" = "relaxed" ]; then
            log_msg "[GPU][ADAPT] ultra re-locked at $((target / 1000000))MHz (important scene: hot thread detected)"
        fi
        GPU_ULTRA_LAST_STATE=$state
    fi

    # THEN verify: the write above should make this a no-op; any mismatch
    # means a node REFUSED the value (or a same-instant racing writer), which
    # is exactly what we want in the log. Throttled to one line per 10s.
    local drift="" v
    v=$(cat "$GPU_MAX" 2>/dev/null); [ "$v" != "$target" ] && drift="max=$v "
    v=$(cat "$GPU_MIN" 2>/dev/null); [ "$v" != "$want_min" ] && drift="${drift}min=$v "
    if [ "$locked" = "1" ]; then
        v=$(cat "$GPU_GOVERNOR" 2>/dev/null); [ "$v" != "performance" ] && drift="${drift}gov=$v "
        v=$(cat "$GPU_PATH/max_pwrlevel" 2>/dev/null); [ -n "$v" ] && [ "$v" != "0" ] && drift="${drift}maxpl=$v "
        v=$(cat "$GPU_PATH/min_pwrlevel" 2>/dev/null); [ -n "$v" ] && [ "$v" != "0" ] && drift="${drift}minpl=$v "
        v=$(cat "$GPU_PATH/force_clk_on" 2>/dev/null); [ -n "$v" ] && [ "$v" != "1" ] && drift="${drift}clk=$v "
    else
        v=$(cat "$GPU_GOVERNOR" 2>/dev/null); [ "$v" != "msm-adreno-tz" ] && drift="${drift}gov=$v "
        v=$(cat "$GPU_PATH/max_pwrlevel" 2>/dev/null); [ -n "$v" ] && [ "$v" != "0" ] && drift="${drift}maxpl=$v "
    fi
    [ -z "$drift" ] && return 0
    local now=$(date +%s)
    case "$GPUADAPT_LAST_LOG" in ''|*[!0-9]*) GPUADAPT_LAST_LOG=0 ;; esac
    if [ $((now - GPUADAPT_LAST_LOG)) -ge 10 ] 2>/dev/null; then
        local tpl=$(cat "$GPU_PATH/thermal_pwrlevel" 2>/dev/null)
        log_msg "[GPU][LOCK] write-first re-asserted ${state} $((want_min / 1000000))-$((target / 1000000))MHz (node refused/raced: ${drift}thermal_pl=${tpl:-n/a})"
        GPUADAPT_LAST_LOG=$now
    fi
}

################################################################################
# GPU PER-APP TIER ENGINE (v1.5.4, non-ultra modes)
#
# Below ultra the GPU used to get ONE min/max write at mode-switch time and
# was never touched again - no re-assert, no per-app nuance, and a heavy game
# in balanced mode could watch the governor bounce off the floor between
# frames ("spun up, then dropped again before the frame finished"). This
# engine classifies the foreground app from the learned profile
# (LEARNING_DB's gpu% = how GPU-bound the app historically is) into
# heavy/mid/light and writes a sensible [min,max] band for it, intersected
# with the active mode's range (the mode still wins - a learned band can
# narrow, never exceed it). Apps with too few samples follow the plain mode
# range, exactly like the live-load fallback on the CPU side. The watchdog
# re-asserts the band every second so an external writer can't quietly keep
# the GPU low until the next mode switch.
################################################################################

# Echo "tier|gpup|samples" for the app, or "none|gpup|samples" when the
# sample count is below profile_min_samples (the caller then follows the
# plain mode range).
gpu_app_tier() {
    local pkg=$1
    [ -f "$LEARNING_DB" ] || { echo "none|0|0"; return; }
    local line=$(awk -F'|' -v p="$pkg" '$1 == p {print $2"|"$5; exit}' "$LEARNING_DB" 2>/dev/null)
    local cnt=${line%%|*} gpup=${line##*|}
    case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
    case "$gpup" in ''|*[!0-9]*) gpup=0 ;; esac
    if [ "$cnt" -lt "$GPU_S_MIN_SAMPLES" ] 2>/dev/null; then
        echo "none|$gpup|$cnt"
        return
    fi
    if [ "$gpup" -ge "$GPU_S_HEAVY_PCT" ]; then
        echo "heavy|$gpup|$cnt"
    elif [ "$gpup" -ge "$GPU_S_MID_PCT" ]; then
        echo "mid|$gpup|$cnt"
    else
        echo "light|$gpup|$cnt"
    fi
}

# Echo "gpu_min gpu_max" for a mode (modes.conf first, built-in fallback).
gpu_mode_range() {
    local line="" gmin="" gmax=""
    [ -f "$CONFIG_DIR/modes.conf" ] && line=$(awk -F'|' -v m="$1" '$1 == m {print; exit}' "$CONFIG_DIR/modes.conf" 2>/dev/null)
    if [ -n "$line" ]; then
        gmin=$(echo "$line" | cut -d'|' -f6)
        gmax=$(echo "$line" | cut -d'|' -f7)
    fi
    case "$gmin" in ''|*[!0-9]*) gmin="" ;; esac
    case "$gmax" in ''|*[!0-9]*) gmax="" ;; esac
    if [ -z "$gmin" ] || [ -z "$gmax" ]; then
        case "$1" in
            powersave)   gmin=0;        gmax=267000000 ;;
            performance) gmin=267000000; gmax=825000000 ;;
            ultra)       gmin=825000000; gmax=825000000 ;;
            *)           gmin=0;        gmax=565000000 ;;
        esac
    fi
    echo "$gmin $gmax"
}

# Order-safe devfreq limit write: raising the floor past the CURRENT ceiling
# needs the ceiling lifted first; everything else floors first.
gpu_write_limits() {
    local new_min=$1 new_max=$2
    local cur_max=$(cat "$GPU_MAX" 2>/dev/null)
    case "$cur_max" in ''|*[!0-9]*) cur_max=0 ;; esac
    if [ "$cur_max" -gt 0 ] 2>/dev/null && [ "$new_min" -gt "$cur_max" ] 2>/dev/null; then
        echo "$new_max" > "$GPU_MAX" 2>/dev/null
        echo "$new_min" > "$GPU_MIN" 2>/dev/null
    else
        echo "$new_min" > "$GPU_MIN" 2>/dev/null
        echo "$new_max" > "$GPU_MAX" 2>/dev/null
    fi
}

# Main-loop entry (once per scheduler cycle, after the learning cycle so the
# profile it reads is fresh). Publishes GPU_APP_STATE for the watchdog in
# every mode; writes sysfs itself only outside ultra (ultra's nodes belong
# to the write-first watchdog).
gpu_app_profile_cycle() {
    local pkg=$1
    gpu_sched_load_conf
    if [ "$GPU_S_ENABLED" != "true" ]; then
        rm -f "$GPU_APP_STATE" 2>/dev/null
        return
    fi
    local mode=""
    IFS= read -r mode < "$CONFIG_DIR/.last_mode" 2>/dev/null
    case "$mode" in
        powersave|balanced|performance|ultra) ;;
        *) mode="balanced" ;;
    esac
    if [ -z "$pkg" ]; then
        rm -f "$GPU_APP_STATE" 2>/dev/null
        return
    fi

    local tinfo=$(gpu_app_tier "$pkg")
    local tier=$(echo "$tinfo" | cut -d'|' -f1)
    local gpup=$(echo "$tinfo" | cut -d'|' -f2)
    local cnt=$(echo "$tinfo" | cut -d'|' -f3)

    if [ "$mode" = "ultra" ]; then
        # Ultra: the write-first watchdog owns the GPU nodes; we only publish
        # the tier so its relax hysteresis can favor heavy/light profiles.
        echo "${pkg}|${mode}|${tier}|0|0|$(date +%s)" > "$GPU_APP_STATE" 2>/dev/null
        return
    fi

    local mrange=$(gpu_mode_range "$mode")
    local mode_min=${mrange%% *} mode_max=${mrange##* }
    local app_min=$mode_min app_max=$mode_max
    case "$tier" in
        heavy) app_min=$GPU_S_HEAVY_MIN; app_max=$GPU_S_HEAVY_MAX ;;
        mid)   app_min=$GPU_S_MID_MIN;   app_max=$GPU_S_MID_MAX ;;
        light) app_min=$GPU_S_LIGHT_MIN; app_max=$GPU_S_LIGHT_MAX ;;
        # none: sample-starved apps follow the plain mode range verbatim
    esac
    local tmax=$(gpu_table_max)
    [ "$app_max" -le 0 ] 2>/dev/null && app_max=$tmax
    # Intersect with the active mode's band: the mode always wins.
    local eff_min=$app_min eff_max=$app_max
    [ "$mode_min" -gt "$eff_min" ] 2>/dev/null && eff_min=$mode_min
    [ "$mode_max" -lt "$eff_max" ] 2>/dev/null && eff_max=$mode_max
    [ "$eff_max" -gt "$tmax" ] 2>/dev/null && eff_max=$tmax
    [ "$eff_min" -gt "$eff_max" ] 2>/dev/null && eff_min=$eff_max

    local newstate="${pkg}|${mode}|${tier}|${eff_min}|${eff_max}"
    local oldstate=""
    [ -f "$GPU_APP_STATE" ] && IFS= read -r oldstate < "$GPU_APP_STATE" 2>/dev/null
    oldstate=${oldstate%|*}     # strip the ts field for the comparison
    [ "$newstate" = "$oldstate" ] && return 0

    gpu_write_limits "$eff_min" "$eff_max"
    echo "${newstate}|$(date +%s)" > "$GPU_APP_STATE" 2>/dev/null
    if [ "$tier" = "none" ]; then
        log_msg "[GPU][TIER] $pkg: only ${cnt} samples (< $GPU_S_MIN_SAMPLES), following mode range $((eff_min / 1000000))-$((eff_max / 1000000))MHz"
    else
        log_msg "[GPU][TIER] $pkg tier=$tier (gpu=${gpup}% n=${cnt}) -> band $((eff_min / 1000000))-$((eff_max / 1000000))MHz [mode $mode $((mode_min / 1000000))-$((mode_max / 1000000))]"
    fi
}

# Watchdog path for non-ultra modes: re-assert the published per-app band if
# the live nodes drifted from it (thermal daemons rewrite devfreq limits the
# same way they rewrite the ultra lock). When no usable per-app state exists
# (foreground unknown, app just switched, band not published yet), the MODE
# range is asserted instead: the mode's limits are a hard boundary the GPU
# must never sit outside of - without this fallback a leftover 700MHz ceiling
# from an ultra/performance episode (or an external writer) could survive
# indefinitely, because apply_mode's sentinel only watches the CPU policy.
# Cheap: one tmpfs read + two sysfs reads per second, writes only on drift.
GPUAPP_ASSERT_LAST_LOG=0
gpu_app_assert() {
    local mode=$1
    local st_pkg="" st_mode="" st_tier="" st_min="" st_max="" st_ts=""
    [ -f "$GPU_APP_STATE" ] && IFS='|' read -r st_pkg st_mode st_tier st_min st_max st_ts < "$GPU_APP_STATE" 2>/dev/null
    local want_min="" want_max="" what=""
    if [ "$st_mode" = "$mode" ]; then
        case "$st_min" in ''|*[!0-9]*) st_min="" ;; esac
        case "$st_max" in ''|*[!0-9]*) st_max="" ;; esac
        if [ -n "$st_min" ] && [ -n "$st_max" ] && [ "$st_max" -gt 0 ] 2>/dev/null; then
            want_min=$st_min; want_max=$st_max; what="tier $st_tier"
        fi
    fi
    if [ -z "$want_max" ]; then
        # No usable per-app state: fall back to the mode's own range.
        local mrange=$(gpu_mode_range "$mode")
        want_min=${mrange%% *} want_max=${mrange##* }
        case "$want_min" in ''|*[!0-9]*) return 0 ;; esac
        case "$want_max" in ''|*[!0-9]*) return 0 ;; esac
        local tmax=$(gpu_table_max)
        [ "$want_max" -gt "$tmax" ] 2>/dev/null && want_max=$tmax
        [ "$want_min" -gt "$want_max" ] 2>/dev/null && want_min=$want_max
        what="mode range"
    fi
    local cur_min=$(cat "$GPU_MIN" 2>/dev/null) cur_max=$(cat "$GPU_MAX" 2>/dev/null)
    [ "$cur_min" = "$want_min" ] && [ "$cur_max" = "$want_max" ] && return 0
    gpu_write_limits "$want_min" "$want_max"
    local now=$(date +%s)
    case "$GPUAPP_ASSERT_LAST_LOG" in ''|*[!0-9]*) GPUAPP_ASSERT_LAST_LOG=0 ;; esac
    if [ $((now - GPUAPP_ASSERT_LAST_LOG)) -ge 10 ] 2>/dev/null; then
        log_msg "[GPU][TIER] re-asserted $what $((want_min / 1000000))-$((want_max / 1000000))MHz (mode $mode${st_pkg:+, state $st_pkg/$st_mode}; drift: min=${cur_min:-n/a} max=${cur_max:-n/a})"
        GPUAPP_ASSERT_LAST_LOG=$now
    fi
}

# Write-first watchdog: while ultra is active it REWRITES the whole lock
# stack every lock_write_interval (default 1s, sub-second allowed) and only
# then reads back for verification - a thermal engine that clamps the GPU is
# corrected by the next write, not discovered by the next read. In non-ultra
# modes it re-asserts the per-app tier band on drift (1s). Inherits the
# daemon's LITTLE mask from service.sh so it never touches a big core.
# NOTE: the pid file (GPU_WD_PID) is managed by the LAUNCHER, not here - a
# backgrounded subshell sees the PARENT's pid in $$ (POSIX), so a
# self-written pid file would point at the main service loop and a stale-pid
# kill would murder the scheduler instead of the old watchdog. service.sh
# kills the previous pid and records $! after forking.
gpu_lock_watchdog() {
    gpu_sched_load_conf
    log_msg "[GPU][LOCK] watchdog started (write-first interval=${GPU_S_INTERVAL}s, adaptive floor $((GPU_S_FLOOR_EFF / 1000000))MHz, engine=$GPU_S_ENABLED)"
    local mode="" cycle=0
    GPU_ULTRA_RELAX_CNT=0; GPU_ULTRA_LAST_STATE=""
    while true; do
        cycle=$((cycle + 1))
        # Live-tunable knobs: re-read the conf roughly every 10 cycles.
        [ $((cycle % 10)) -eq 1 ] && gpu_sched_load_conf
        mode=""
        IFS= read -r mode < "$CONFIG_DIR/.last_mode" 2>/dev/null
        if [ "$GPU_S_ENABLED" != "true" ]; then
            # Engine disabled: fall back to the v1.5.3 verify-only behavior.
            if [ "$mode" = "ultra" ]; then
                gpu_ultra_verify
                sleep 1
            else
                [ -f "$GPU_LOCK_STATE" ] && gpu_ultra_unlock "mode=${mode:-unknown}"
                sleep 3
            fi
            continue
        fi
        if [ "$mode" = "ultra" ]; then
            gpu_ultra_maintain
            sleep "$GPU_S_INTERVAL"
        else
            GPU_ULTRA_RELAX_CNT=0; GPU_ULTRA_LAST_STATE=""
            # Safety net: a lock state that survived an abnormal apply path
            # is released here even if the mode switch itself missed it.
            if [ -f "$GPU_LOCK_STATE" ]; then
                gpu_ultra_unlock "mode=${mode:-unknown}"
            else
                gpu_app_assert "${mode:-unknown}"
            fi
            sleep 1
        fi
    done
}

apply_powersave() {
    echo "300000" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
    echo "1401600" > "$CPU_BASE/cpufreq/policy0/scaling_max_freq" 2>/dev/null
    echo "300000" > "$CPU_BASE/cpufreq/policy6/scaling_min_freq" 2>/dev/null
    echo "1324800" > "$CPU_BASE/cpufreq/policy6/scaling_max_freq" 2>/dev/null
    echo "schedutil" > "$CPU_BASE/cpufreq/policy0/scaling_governor" 2>/dev/null
    echo "schedutil" > "$CPU_BASE/cpufreq/policy6/scaling_governor" 2>/dev/null
    gpu_ultra_unlock "mode powersave"
    apply_gpu_limits "0" "267000000"
    echo "0" > /proc/sys/kernel/sched_boost 2>/dev/null
}

apply_balanced() {
    echo "300000" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
    echo "1804800" > "$CPU_BASE/cpufreq/policy0/scaling_max_freq" 2>/dev/null
    echo "300000" > "$CPU_BASE/cpufreq/policy6/scaling_min_freq" 2>/dev/null
    echo "2208000" > "$CPU_BASE/cpufreq/policy6/scaling_max_freq" 2>/dev/null
    echo "schedutil" > "$CPU_BASE/cpufreq/policy0/scaling_governor" 2>/dev/null
    echo "schedutil" > "$CPU_BASE/cpufreq/policy6/scaling_governor" 2>/dev/null
    gpu_ultra_unlock "mode balanced"
    apply_gpu_limits "0" "565000000"
    echo "1" > /proc/sys/kernel/sched_boost 2>/dev/null
}

apply_performance() {
    echo "300000" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
    echo "1804800" > "$CPU_BASE/cpufreq/policy0/scaling_max_freq" 2>/dev/null
    echo "1401600" > "$CPU_BASE/cpufreq/policy6/scaling_min_freq" 2>/dev/null
    echo "2208000" > "$CPU_BASE/cpufreq/policy6/scaling_max_freq" 2>/dev/null
    echo "schedutil" > "$CPU_BASE/cpufreq/policy0/scaling_governor" 2>/dev/null
    echo "schedutil" > "$CPU_BASE/cpufreq/policy6/scaling_governor" 2>/dev/null
    gpu_ultra_unlock "mode performance"
    apply_gpu_limits "267000000" "825000000"
    echo "1" > /proc/sys/kernel/sched_boost 2>/dev/null
}

apply_ultra() {
    echo "1401600" > "$CPU_BASE/cpufreq/policy0/scaling_min_freq" 2>/dev/null
    echo "1804800" > "$CPU_BASE/cpufreq/policy0/scaling_max_freq" 2>/dev/null
    echo "2208000" > "$CPU_BASE/cpufreq/policy6/scaling_min_freq" 2>/dev/null
    echo "2208000" > "$CPU_BASE/cpufreq/policy6/scaling_max_freq" 2>/dev/null
    echo "performance" > "$CPU_BASE/cpufreq/policy0/scaling_governor" 2>/dev/null
    echo "performance" > "$CPU_BASE/cpufreq/policy6/scaling_governor" 2>/dev/null
    gpu_ultra_lock "825000000" "825000000"
    echo "1" > /proc/sys/kernel/sched_boost 2>/dev/null
}

# Legacy whole-app affinity: one learned mask for every thread of the app.
# Fork-storm control: threads inherit their creator's mask, so once every
# thread of the app carries the right mask there is nothing to do until the
# mask itself changes. The old code forked taskset for EVERY thread EVERY
# cycle (60-100 forks per 3s in powersave mode).
#
# Failure handling: the state file is written ONLY when every bind verified
# against the kernel - a partial failure is retried in full on the next cycle
# (already-correct threads short-circuit in aff_bind_tid's read-back fast
# path, so retries cost no taskset forks). Every 5th cycle the masks are
# re-verified even when the state matches, so an external actor that resets
# the app's affinity behind our back gets corrected instead of winning
# silently.
apply_app_affinity_legacy() {
    local pkg=$1
    local mode=$2
    [ -z "$pkg" ] && return

    local mask=$(get_affinity_mask "$pkg" "$mode")
    local pids=$(get_app_pids "$pkg")
    [ -z "$pids" ] && return

    local first_pid=${pids%% *}
    local last=""
    [ -f "$LEGACY_AFF_STATE" ] && IFS= read -r last < "$LEGACY_AFF_STATE" 2>/dev/null
    if [ "$last" = "$pkg|$mask|$first_pid" ] && [ $((AFF_CYCLE % 5)) -ne 0 ]; then
        return      # unchanged: children inherit, nothing to re-apply
    fi

    local pid tid_path tid ok=0 fail=0 deferred=0
    for pid in $pids; do
        [ -d "/proc/$pid/task" ] || continue
        for tid_path in /proc/$pid/task/*; do
            [ -d "$tid_path" ] || continue
            tid=${tid_path##*/}
            case "$tid" in
                *[!0-9]*) continue ;;
            esac
            if aff_bind_tid "$tid" "$mask" "LEGACY $pkg/$mode"; then
                ok=$((ok + 1))
            else
                case "$AFF_LAST" in
                    defer|clamped) deferred=$((deferred + 1)) ;;
                    dead) ;;
                    *) [ -d "/proc/$tid" ] && fail=$((fail + 1)) ;;
                esac
            fi
        done
    done
    if [ "$fail" -eq 0 ] && [ "$deferred" -eq 0 ]; then
        echo "$pkg|$mask|$first_pid" > "$LEGACY_AFF_STATE" 2>/dev/null
    elif [ "$fail" -eq 0 ]; then
        log_msg "[AFF] $pkg: whole-app mask 0x$mask applied where reachable (verified ok=$ok deferred=$deferred by cpuset) - completing as groups move"
    else
        log_msg "[AFF] $pkg: whole-app mask 0x$mask partially applied (verified ok=$ok failed=$fail deferred=$deferred) - retrying next cycle"
    fi
}

################################################################################
# THREAD PIN ENGINE
#
# Per-thread affinity for the SD730's 2+6 topology. The whole-app mask treats
# every thread alike, but in reality 1-3 threads (game main/render loop, codec
# workers) do most of the work. This engine:
#   1. samples EVERY thread's instantaneous CPU% (jiffies delta per-tid, same
#      method as get_app_cpu_load),
#   2. pins sustained-hot threads to the big cluster (0xC0) with hysteresis;
#      everything else keeps the mode's learned whole-app mask,
#   3. ELASTIC BUDGET: normally at most base_pinned_threads (2) pins - one per
#      A76 core. When a THIRD thread stays hot while the top two saturate both
#      big cores (and thermals allow), the budget expands to
#      max_pinned_threads (3), and contracts again when the third cools down,
#   4. learns which thread NAMES stay hot per app (thread_learning.db) and
#      pre-pins them by name at the next launch - no sampling wait,
#   5. can self-pin the daemon to the LITTLE cluster (self_pin_little) so the
#      module's own overhead never occupies an A76.
#
# Cost control: config is parsed with zero forks (single read pass), thread
# stats are read with shell builtins only, and taskset runs ONLY for threads
# whose target mask actually changed (steady state: ~0 forks per cycle).
################################################################################

TPIN_CONF="$CONFIG_DIR/thread_pin.conf"
TPIN_STATE="/data/local/tmp/sd730-tpin.state"
THREAD_LEARN_DB="$CONFIG_DIR/thread_learning.db"
# Thread correlation prediction: which thread gets hot BECAUSE another one did
TCORR_DB="$CONFIG_DIR/thread_corr.db"
TCORR_STATE="/data/local/tmp/sd730-tcorr.state"
TCORR_HIST="/data/local/tmp/sd730-tcorr.hist"
# Self-management detection: tmpfs session counters + persistent verdict DB
SELFM_STATE="/data/local/tmp/sd730-selfm.state"
SELFM_DB="$CONFIG_DIR/selfmanage.db"
# Legacy whole-app path: last applied pkg|mask (skip redundant taskset storms)
LEGACY_AFF_STATE="/data/local/tmp/sd730-legacy.state"

# Engine defaults (mirrored in config/thread_pin.conf and customize.sh).
TP_ENABLED="true"
TP_PIN_MODES="balanced performance ultra"
TP_HOT=25
TP_REL=15
TP_HOT_STREAK=2
TP_REL_STREAK=3
TP_BASE_CAP=2
TP_MAX_CAP=3
TP_ESC_TH=40
TP_ESC_PAIR=120
TP_ESC_STREAK=2
TP_ESC_TEMP=72
TP_REL_TEMP=78
TP_BIG_MASK="c0"
TP_SELF_PIN="true"
TP_SELF_MASK="3f"
TP_PIN_NAMES=""
TP_BLACKLIST="Jit|GC|Finalizer|HeapTaskDaemon|JDWP|Signal Catcher|ReferenceQueue"
TP_TLEARN="true"
TP_TLEARN_MIN_SAMPLES=5
TP_TLEARN_MIN_SHARE=60
TP_TLEARN_MIN_CPU=10
# Thread correlation prediction defaults
TP_TCORR="true"
TP_TCORR_WIN=12
TP_TCORR_MIN_SAMPLES=8
TP_TCORR_MIN_SHARE=60
TP_TCORR_REL_STREAK=2
TP_TCORR_NICE=-3
TP_TCORR_PIN="true"
# Slot displacement: a genuinely-hot candidate may evict the coolest pinned
# keeper when it is this many CPU points hotter (or the keeper is currently
# below release_threshold). Prevents lukewarm keepers (16-24% hysteresis
# band) from occupying big-core slots forever while a 60%+ thread starves.
TP_DISPLACE=15
# Mask learning gate + live-load fallback for apps with too few samples.
TP_MASK_MIN_SAMPLES=6
TP_FB_LIGHT=25
# Cold-thread mask splitter: an UNPINNED thread never gets the raw coarse
# mask; it is narrowed by the thread's own live CPU% (all values = % of one
# core). >=TP_COLD_FULL keeps the full coarse mask (its big-core bits incl.,
# i.e. only near-hot threads may reach cpu6-7 unpinned), >=TP_COLD_WIDE gets
# the coarse mask's little-cluster portion, >=TP_COLD_MID gets cpu0-3, and
# anything below idles on cpu0-1. Tier boundaries double as power vs.
# spread trade-offs; set via thread_pin.conf (cold_*_mask_cpu).
TP_COLD_FULL=20
TP_COLD_WIDE=8
TP_COLD_MID=3
# Self-management detection: apps that place their own hot threads well are
# only monitored, not touched; heavy threads on wrong cores revoke that.
TP_SELFM="true"
TP_SELFM_STREAK=5
TP_SELFM_INT_CPU=45
TP_SELFM_INT_STREAK=2
TP_SELFM_OBS_MAX=8

# Load thread_pin.conf into the TP_* globals in ONE read pass. read_cfg would
# fork grep+cut+tr per key; the daemon needs these values every 3s.
tpin_load_conf() {
    TP_ENABLED="true"; TP_PIN_MODES="balanced performance ultra"
    TP_HOT=25; TP_REL=15; TP_HOT_STREAK=2; TP_REL_STREAK=3
    TP_BASE_CAP=2; TP_MAX_CAP=3
    TP_ESC_TH=40; TP_ESC_PAIR=120; TP_ESC_STREAK=2; TP_ESC_TEMP=72
    TP_REL_TEMP=78; TP_BIG_MASK="c0"
    TP_SELF_PIN="true"; TP_SELF_MASK="3f"
    TP_PIN_NAMES=""
    TP_BLACKLIST="Jit|GC|Finalizer|HeapTaskDaemon|JDWP|Signal Catcher|ReferenceQueue"
    TP_TLEARN="true"; TP_TLEARN_MIN_SAMPLES=5; TP_TLEARN_MIN_SHARE=60; TP_TLEARN_MIN_CPU=10
    TP_TCORR="true"; TP_TCORR_WIN=12; TP_TCORR_MIN_SAMPLES=8; TP_TCORR_MIN_SHARE=60
    TP_TCORR_REL_STREAK=2; TP_TCORR_NICE=-3; TP_TCORR_PIN="true"
    TP_DISPLACE=15; TP_MASK_MIN_SAMPLES=6; TP_FB_LIGHT=25
    TP_COLD_FULL=20; TP_COLD_WIDE=8; TP_COLD_MID=3
    TP_SELFM="true"; TP_SELFM_STREAK=5; TP_SELFM_INT_CPU=45
    TP_SELFM_INT_STREAK=2; TP_SELFM_OBS_MAX=8
    # v3.3: 模型参与绑核分配 (权重式)
    TP_NN_MANAGE="true"; TP_NN_MAX_ADJ=25
    TP_NN_ESC="true"; TP_NN_ESC_SCORE=0.50; TP_NN_ESC_SMOOTH=0.70
    TP_NN_BALANCE="true"; TP_NN_BALANCE_TOP=4
    [ -f "$TPIN_CONF" ] || return
    local k v
    while IFS='=' read -r k v; do
        case "$v" in *$'\r') v=${v%$'\r'} ;; esac
        case "$k" in
            ''|\#*) continue ;;
            thread_pin_enabled) TP_ENABLED=$v ;;
            pin_modes) TP_PIN_MODES=$v ;;
            hot_threshold) TP_HOT=$v ;;
            release_threshold) TP_REL=$v ;;
            hot_streak) TP_HOT_STREAK=$v ;;
            release_streak) TP_REL_STREAK=$v ;;
            base_pinned_threads) TP_BASE_CAP=$v ;;
            max_pinned_threads) TP_MAX_CAP=$v ;;
            escalate_threshold) TP_ESC_TH=$v ;;
            escalate_pair_load) TP_ESC_PAIR=$v ;;
            escalate_streak) TP_ESC_STREAK=$v ;;
            escalate_temp_max) TP_ESC_TEMP=$v ;;
            release_temp) TP_REL_TEMP=$v ;;
            big_mask) TP_BIG_MASK=$v ;;
            self_pin_enabled) TP_SELF_PIN=$v ;;
            self_mask) TP_SELF_MASK=$v ;;
            pin_names) TP_PIN_NAMES=$v ;;
            name_blacklist) TP_BLACKLIST=$v ;;
            tlearn_enabled) TP_TLEARN=$v ;;
            tlearn_min_samples) TP_TLEARN_MIN_SAMPLES=$v ;;
            tlearn_min_share) TP_TLEARN_MIN_SHARE=$v ;;
            tlearn_min_cpu) TP_TLEARN_MIN_CPU=$v ;;
            tcorr_enabled) TP_TCORR=$v ;;
            tcorr_window_seconds) TP_TCORR_WIN=$v ;;
            tcorr_min_samples) TP_TCORR_MIN_SAMPLES=$v ;;
            tcorr_min_share) TP_TCORR_MIN_SHARE=$v ;;
            tcorr_release_streak) TP_TCORR_REL_STREAK=$v ;;
            tcorr_nice_boost) TP_TCORR_NICE=$v ;;
            tcorr_pin_candidate) TP_TCORR_PIN=$v ;;
            displace_margin) TP_DISPLACE=$v ;;
            mask_min_samples) TP_MASK_MIN_SAMPLES=$v ;;
            fallback_light_load) TP_FB_LIGHT=$v ;;
            cold_full_mask_cpu) TP_COLD_FULL=$v ;;
            cold_wide_mask_cpu) TP_COLD_WIDE=$v ;;
            cold_mid_mask_cpu) TP_COLD_MID=$v ;;
            selfmanage_enabled) TP_SELFM=$v ;;
            selfmanage_streak) TP_SELFM_STREAK=$v ;;
            selfmanage_intervene_cpu) TP_SELFM_INT_CPU=$v ;;
            selfmanage_intervene_streak) TP_SELFM_INT_STREAK=$v ;;
            selfmanage_observe_max) TP_SELFM_OBS_MAX=$v ;;
            # v3.3: 模型分配
            nn_manage) TP_NN_MANAGE=$v ;;
            nn_max_adjust) TP_NN_MAX_ADJ=$v ;;
            nn_esc_enabled) TP_NN_ESC=$v ;;
            nn_esc_score) TP_NN_ESC_SCORE=$v ;;
            nn_esc_smooth) TP_NN_ESC_SMOOTH=$v ;;
            nn_balance_little) TP_NN_BALANCE=$v ;;
            nn_balance_top) TP_NN_BALANCE_TOP=$v ;;
        esac
    done < "$TPIN_CONF"
    # Numeric sanitation: garbage falls back to the defaults.
    case "$TP_HOT" in ''|*[!0-9]*) TP_HOT=25 ;; esac
    case "$TP_REL" in ''|*[!0-9]*) TP_REL=15 ;; esac
    case "$TP_HOT_STREAK" in ''|*[!0-9]*) TP_HOT_STREAK=2 ;; esac
    case "$TP_REL_STREAK" in ''|*[!0-9]*) TP_REL_STREAK=3 ;; esac
    case "$TP_BASE_CAP" in ''|*[!0-9]*) TP_BASE_CAP=2 ;; esac
    case "$TP_MAX_CAP" in ''|*[!0-9]*) TP_MAX_CAP=3 ;; esac
    case "$TP_ESC_TH" in ''|*[!0-9]*) TP_ESC_TH=40 ;; esac
    case "$TP_ESC_PAIR" in ''|*[!0-9]*) TP_ESC_PAIR=120 ;; esac
    case "$TP_ESC_STREAK" in ''|*[!0-9]*) TP_ESC_STREAK=2 ;; esac
    case "$TP_ESC_TEMP" in ''|*[!0-9]*) TP_ESC_TEMP=72 ;; esac
    case "$TP_REL_TEMP" in ''|*[!0-9]*) TP_REL_TEMP=78 ;; esac
    case "$TP_TLEARN_MIN_SAMPLES" in ''|*[!0-9]*) TP_TLEARN_MIN_SAMPLES=5 ;; esac
    case "$TP_TLEARN_MIN_SHARE" in ''|*[!0-9]*) TP_TLEARN_MIN_SHARE=60 ;; esac
    case "$TP_TLEARN_MIN_CPU" in ''|*[!0-9]*) TP_TLEARN_MIN_CPU=10 ;; esac
    case "$TP_TCORR_WIN" in ''|*[!0-9]*) TP_TCORR_WIN=12 ;; esac
    case "$TP_TCORR_MIN_SAMPLES" in ''|*[!0-9]*) TP_TCORR_MIN_SAMPLES=8 ;; esac
    case "$TP_TCORR_MIN_SHARE" in ''|*[!0-9]*) TP_TCORR_MIN_SHARE=60 ;; esac
    case "$TP_TCORR_REL_STREAK" in ''|*[!0-9]*) TP_TCORR_REL_STREAK=2 ;; esac
    case "$TP_TCORR_NICE" in ''|*[!0-9-]*) TP_TCORR_NICE=-3 ;; esac
    # nice clamp: boosting below -20 / above 19 is impossible, keep a margin
    [ "$TP_TCORR_NICE" -lt -10 ] 2>/dev/null && TP_TCORR_NICE=-10
    [ "$TP_TCORR_NICE" -gt 10 ] 2>/dev/null && TP_TCORR_NICE=10
    case "$TP_DISPLACE" in ''|*[!0-9]*) TP_DISPLACE=15 ;; esac
    case "$TP_MASK_MIN_SAMPLES" in ''|*[!0-9]*) TP_MASK_MIN_SAMPLES=6 ;; esac
    case "$TP_FB_LIGHT" in ''|*[!0-9]*) TP_FB_LIGHT=25 ;; esac
    case "$TP_COLD_FULL" in ''|*[!0-9]*) TP_COLD_FULL=20 ;; esac
    case "$TP_COLD_WIDE" in ''|*[!0-9]*) TP_COLD_WIDE=8 ;; esac
    case "$TP_COLD_MID" in ''|*[!0-9]*) TP_COLD_MID=3 ;; esac
    # keep the tier order sane even with a hand-edited conf
    [ "$TP_COLD_MID" -gt "$TP_COLD_WIDE" ] 2>/dev/null && TP_COLD_MID=$TP_COLD_WIDE
    [ "$TP_COLD_WIDE" -gt "$TP_COLD_FULL" ] 2>/dev/null && TP_COLD_WIDE=$TP_COLD_FULL
    case "$TP_SELFM_STREAK" in ''|*[!0-9]*) TP_SELFM_STREAK=5 ;; esac
    case "$TP_SELFM_INT_CPU" in ''|*[!0-9]*) TP_SELFM_INT_CPU=45 ;; esac
    case "$TP_SELFM_INT_STREAK" in ''|*[!0-9]*) TP_SELFM_INT_STREAK=2 ;; esac
    case "$TP_SELFM_OBS_MAX" in ''|*[!0-9]*) TP_SELFM_OBS_MAX=8 ;; esac
    case "$TP_NN_MAX_ADJ" in ''|*[!0-9]*) TP_NN_MAX_ADJ=25 ;; esac
    [ "$TP_NN_MAX_ADJ" -gt 50 ] 2>/dev/null && TP_NN_MAX_ADJ=50
    case "$TP_NN_ESC_SCORE" in ''|*[!0-9.]*) TP_NN_ESC_SCORE=0.50 ;; esac
    case "$TP_NN_ESC_SMOOTH" in ''|*[!0-9.]*) TP_NN_ESC_SMOOTH=0.70 ;; esac
    case "$TP_NN_BALANCE_TOP" in ''|*[!0-9]*) TP_NN_BALANCE_TOP=4 ;; esac
    # normalize both masks: lowercase hex without 0x prefix / leading zeros,
    # so string comparisons with read-back masks are exact. (The binding core
    # re-normalizes again at bind time, incl. decimal-trap self-healing.)
    TP_BIG_MASK=${TP_BIG_MASK#0x}
    while [ "${TP_BIG_MASK#0}" != "$TP_BIG_MASK" ] && [ ${#TP_BIG_MASK} -gt 1 ]; do
        TP_BIG_MASK=${TP_BIG_MASK#0}
    done
    case "$TP_BIG_MASK" in ''|*[!0-9a-f]*) TP_BIG_MASK="c0" ;; esac
    TP_SELF_MASK=${TP_SELF_MASK#0x}
    while [ "${TP_SELF_MASK#0}" != "$TP_SELF_MASK" ] && [ ${#TP_SELF_MASK} -gt 1 ]; do
        TP_SELF_MASK=${TP_SELF_MASK#0}
    done
    case "$TP_SELF_MASK" in ''|*[!0-9a-f]*) TP_SELF_MASK="3f" ;; esac
}

# Write the default config (used by the CLI if the file went missing;
# customize.sh writes the same file at install time).
tpin_write_default_conf() {
    [ -f "$TPIN_CONF" ] && return 0
    cat > "$TPIN_CONF" <<'EOF'
# SD730 Smart Scheduler - Thread Pin Engine Configuration
#
# Per-thread hot pinning for the 2+6 topology (big = cpu6-7 = 0xC0).
# Normally at most base_pinned_threads hot threads are locked to the big
# cluster; the budget elastically expands to max_pinned_threads while a THIRD
# thread stays heavy AND the top two saturate both A76 cores.
# Read live every scheduler cycle (~3s). No reboot needed.

thread_pin_enabled=true

# Modes in which per-thread pinning is active (space-separated).
pin_modes=balanced performance ultra

# Hot/cold classification, in % of ONE core (per-tid jiffies delta).
hot_threshold=25
release_threshold=15

# Hysteresis: consecutive cycles above hot_threshold before pinning,
# consecutive cycles below release_threshold before unpinning.
hot_streak=2
release_streak=3

# Elastic big-core budget: normal pin slots / expanded pin slots.
base_pinned_threads=2
max_pinned_threads=3

# Expansion triggers (ALL must hold for escalate_streak consecutive cycles):
#   3rd-hottest thread >= escalate_threshold (percent of one core)
#   top1+top2 loads   >= escalate_pair_load  (both A76 cores genuinely busy)
#   temperature       <  escalate_temp_max   (thermal headroom required)
escalate_threshold=40
escalate_pair_load=120
escalate_streak=2
escalate_temp_max=72

# Hard thermal release: drop ALL pins at/above this temperature. Pinning only
# relocates existing hot load (it creates none), so this sits just above the
# module's ultra->performance thermal guard (75C).
release_temp=78

# Mask for pinned threads (hex, no 0x). c0 = cpu6-7.
big_mask=c0

# Pin the scheduler daemon itself to these cores (hex, no 0x) so the module's
# own overhead (dumpsys, /proc sampling, learning) never touches big cores.
self_pin_enabled=true
self_mask=3f

# Manual instant-pin list (comma-separated thread names, exact match),
# e.g. pin_names=UnityMain,UnityGfxDeviceW,RenderThread
pin_names=

# Threads whose name CONTAINS any of these (|-separated) are never pinned
# and never recorded by the name learner.
name_blacklist=Jit|GC|Finalizer|HeapTaskDaemon|JDWP|Signal Catcher|ReferenceQueue

# Thread-name learning: remember which thread names stay hot per app and
# pre-pin them by name at the next launch (no sampling wait).
tlearn_enabled=true
tlearn_min_samples=5
tlearn_min_share=60
tlearn_min_cpu=10

# Thread correlation prediction: learn "when thread A runs hot, thread B
# follows within tcorr_window_seconds". While A stays hot, B's live threads
# get an advance nice boost (and, if tcorr_pin_candidate=true, become big-core
# pin candidates without waiting for the hot streak). When A cools for
# tcorr_release_streak cycles the boost is reverted (both directions exist:
# boost on predicted heat-up, restore on predicted cool-down).
tcorr_enabled=true
tcorr_window_seconds=12
tcorr_min_samples=8
tcorr_min_share=60
tcorr_release_streak=2

# Nice delta applied to predicted threads (negative = higher priority,
# clamped to [-10,10]; absolute nice is clamped to [-20,19]). 0 disables the
# nice boost and keeps only the pin-candidate fast path.
tcorr_nice_boost=-3

# Let correlation-predicted threads skip the hot_streak wait and compete for
# big-core pin slots immediately (still subject to the elastic budget).
tcorr_pin_candidate=true

# Slot displacement: a genuinely-hot candidate (>= hot_threshold) evicts the
# coolest pinned keeper when it is this many CPU points hotter, or when the
# keeper is currently below release_threshold. 0 disables displacement.
displace_margin=15

# Whole-app mask learning gate. Below mask_min_samples the coarse ceiling is
# the full LITTLE cluster (0x3f) in every mode; the cold splitter narrows it
# per-thread. (fallback_light_load retired in v1.5.3 - still parsed, no effect.)
mask_min_samples=6
fallback_light_load=25

# Cold-thread mask splitter (v1.5.3): an UNPINNED thread's mask is narrowed
# by its own live CPU% (% of one core): >=cold_full_mask_cpu keeps the full
# coarse mask (big-core bits incl. - the only unpinned path to cpu6-7),
# >=cold_wide_mask_cpu gets the little-cluster portion (0x3f),
# >=cold_mid_mask_cpu gets cpu0-3 (0x0f), below it idles on cpu0-1 (0x03).
cold_full_mask_cpu=20
cold_wide_mask_cpu=8
cold_mid_mask_cpu=3

# Self-management detection: observe unknown apps, monitor excellent ones
# hands-off, take over immediately when a heavy thread strands off big cores.
selfmanage_enabled=true
selfmanage_streak=5
selfmanage_intervene_cpu=45
selfmanage_intervene_streak=2
selfmanage_observe_max=8
EOF
    chmod 0644 "$TPIN_CONF" 2>/dev/null
}

# Pin the scheduler's own shell (and everything it forks afterwards) to the
# LITTLE cluster: the daemon runs dumpsys + /proc scans + learning math every
# 3s, and that overhead must never occupy an A76.
self_pin_little() {
    tpin_load_conf
    [ "$TP_SELF_PIN" = "true" ] || return 0
    if aff_bind_tid "$$" "$TP_SELF_MASK" "TPIN self-pin"; then
        log_msg "[TPIN] Daemon self-pinned to 0x$(aff_mask_normalize "$TP_SELF_MASK") (LITTLE cluster, verified)"
    else
        log_msg "[TPIN][WARN] daemon self-pin to 0x$TP_SELF_MASK FAILED - the module's own overhead will also run on big cores (see [AFF][FAIL] lines)"
    fi
}

# Read a thread's CURRENT effective affinity as a normalized lowercase hex
# mask, fork-free. Handles both kernel formats ("ff" and the 32-bit chunked
# "00000000,000000ff"). This is the engine's eyes: the module used to trust
# only its own state file and never noticed when the app itself (or another
# tool) overwrote the affinity behind its back - from then on target==applied
# made it skip taskset forever and the external actor won silently.
read_tid_mask_hex() {
    local f="/proc/$1/task/$2/status" l m=""
    [ -r "$f" ] || return 1            # dead thread: avoid a redirect error
    while IFS= read -r l; do
        case "$l" in
            Cpus_allowed:*)
                m=${l#*:}
                set -- $m              # collapse whitespace -> $1
                m=${1##*,}             # keep the lowest 32-bit chunk
                while [ "${m#0}" != "$m" ] && [ ${#m} -gt 1 ]; do m=${m#0}; done
                break
                ;;
        esac
    done < "$f"
    [ -n "$m" ] && echo "$m"
}

# Self-management verdict DB: lines  pkg|verdict|ts  (verdict = excellent|bad)
# Prints "verdict|ts" so callers can age out stale verdicts.
selfm_get_verdict() {
    [ -f "$SELFM_DB" ] || return
    awk -F'|' -v pkg="$1" '$1 == pkg {print $2"|"$3; exit}' "$SELFM_DB" 2>/dev/null
}

selfm_set_verdict() {
    local pkg=$1 verdict=$2 now=$(date +%s)
    [ -f "$SELFM_DB" ] || touch "$SELFM_DB" 2>/dev/null
    [ -f "$SELFM_DB" ] || return
    chmod 0644 "$SELFM_DB" 2>/dev/null
    local tmp="${SELFM_DB}.tmp.$$"
    awk -F'|' -v OFS='|' -v pkg="$pkg" -v v="$verdict" -v now="$now" '
        $1 == pkg { $2 = v; $3 = now; found = 1 }
        { print }
        END { if (!found) printf "%s|%s|%s\n", pkg, v, now }
    ' "$SELFM_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$SELFM_DB" 2>/dev/null
    local lines=$(wc -l < "$SELFM_DB" 2>/dev/null)
    case "$lines" in ''|*[!0-9]*) return ;; esac
    [ "$lines" -le 200 ] && return
    sort -t'|' -k3,3 -rn "$SELFM_DB" 2>/dev/null | head -n 150 > "$tmp" \
        && mv "$tmp" "$SELFM_DB" 2>/dev/null
}

# Restore every big-pinned thread recorded in the state file, then clear the
# state. Each thread goes back to the mask IT had before the module first
# touched it (recorded in state field 12 - e.g. a game's own 0x60 survives);
# the caller's mask is only the fallback when no original was recorded.
# Used on app switch, over-temperature, mode exit and manual reset.
release_all_pins() {
    local defmask=${1:-ff}
    local reason=${2:-unknown}
    [ -f "$TPIN_STATE" ] || return 0
    local tag tid tgid starttime j ts cpu hs cs target applied orig
    local released=0 failed=0 deferred=0 rmask
    while IFS='|' read -r tag tid tgid starttime j ts cpu hs cs target applied orig; do
        [ "$tag" = "TID" ] || continue
        if [ "$target" = "$TP_BIG_MASK" ] || [ "$applied" = "$TP_BIG_MASK" ]; then
            if [ -d "/proc/$tgid/task/$tid" ]; then
                rmask=$orig
                case "$rmask" in ''|*[!0-9a-fA-F]*) rmask=$defmask ;; esac
                case "$rmask" in '') rmask=ff ;; esac
                if aff_bind_tid "$tid" "$rmask" "TPIN release"; then
                    released=$((released + 1))
                else
                    case "$AFF_LAST" in
                        defer|clamped)
                            # the original mask is outside the thread's
                            # current cpuset: the kernel already re-manages
                            # the mask itself - this is NOT a failure
                            deferred=$((deferred + 1)) ;;
                        dead) ;;    # thread gone: nothing left to restore
                        *) [ -d "/proc/$tid" ] && failed=$((failed + 1)) ;;
                    esac
                fi
            fi
        fi
    done < "$TPIN_STATE"
    rm -f "$TPIN_STATE" 2>/dev/null
    [ "$released" -gt 0 ] && log_msg "[TPIN] Released $released pinned thread(s) -> original masks (fallback 0x$defmask, verified) ($reason)"
    [ "$deferred" -gt 0 ] && log_msg "[TPIN] $deferred thread(s) left on their current mask: original mask unreachable under the present cpuset; Android already re-manages them ($reason)"
    [ "$failed" -gt 0 ] && log_msg "[TPIN][WARN] $failed thread(s) could NOT be released ($reason) - their pins remain; see [AFF][FAIL] lines"
    return 0
}

# Record one (pkg, thread-name, cpu) observation into thread_learning.db
# (alpha=30 weighted moving average, same learning rate as the app engine).
# A name becomes pre-pinnable with tlearn_min_samples samples AND a hot share
# (fraction of observations at/above hot_threshold) >= tlearn_min_share.
tlearn_record() {
    local pkg=$1
    local comm=$2
    local cpu=$3
    case "$comm" in *'|'*) return ;; esac
    [ -f "$THREAD_LEARN_DB" ] || touch "$THREAD_LEARN_DB" 2>/dev/null
    [ -f "$THREAD_LEARN_DB" ] || return
    chmod 0644 "$THREAD_LEARN_DB" 2>/dev/null
    local now=$(date +%s)
    local tmp="${THREAD_LEARN_DB}.tmp.$$"
    awk -F'|' -v OFS='|' -v pkg="$pkg" -v comm="$comm" -v cpu="$cpu" \
        -v hot="$TP_HOT" -v now="$now" '
        $1 == pkg && $2 == comm {
            $3 += 1
            $4 = int((30 * cpu + 70 * $4) / 100)
            if (cpu >= hot) $5 += 1
            $6 = now
            found = 1
        }
        { print }
        END {
            if (!found) printf "%s|%s|1|%d|%d|%s\n", pkg, comm, cpu, (cpu >= hot ? 1 : 0), now
        }
    ' "$THREAD_LEARN_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$THREAD_LEARN_DB" 2>/dev/null
}

# Cap the name-learning DB (drop least-recently-seen entries).
tlearn_prune() {
    [ -f "$THREAD_LEARN_DB" ] || return
    local lines=$(wc -l < "$THREAD_LEARN_DB" 2>/dev/null)
    case "$lines" in ''|*[!0-9]*) return ;; esac
    [ "$lines" -le 600 ] && return
    local tmp="${THREAD_LEARN_DB}.tmp.$$"
    sort -t'|' -k6,6 -rn "$THREAD_LEARN_DB" 2>/dev/null | head -n 400 > "$tmp" \
        && mv "$tmp" "$THREAD_LEARN_DB" 2>/dev/null
    log_msg "[TPIN] thread_learning.db pruned ($lines -> 400 entries)"
}

################################################################################
# THREAD CORRELATION PREDICTION
#
# Learns "when thread A of app X runs hot, thread B follows within
# tcorr_window_seconds". While A stays hot, B's live threads are boosted in
# ADVANCE (nice raise + instant big-core pin candidacy); when A cools for
# tcorr_release_streak cycles the boost is reverted. Both directions exist:
# boost on predicted heat-up, restore on predicted cool-down.
#
# DB:  thread_corr.db  lines  pkg|trigger|target|follows|last_ts
#                             pkg|trigger|*|hot_cycles|last_ts   (denominator)
# State (tmpfs): PKG|pkg / CORS|tid|tgid|starttime|name|orig_nice|trigger|misses
# History (tmpfs): ts|name  (recent hot thread names, window-pruned per cycle)
################################################################################

# Read a thread's nice value (field 19 of /proc stat => $17 after comm strip).
tcorr_read_nice() {
    local statline rest
    IFS= read -r statline < "/proc/$1/task/$2/stat" 2>/dev/null
    [ -n "$statline" ] || return 1
    rest=${statline##*)}
    set -- $rest
    case "${17:-}" in ''|*[!0-9-]*) return 1 ;; esac
    echo "${17}"
}

# Set a thread's nice to an ABSOLUTE value, with readback verification.
# toybox renice treats -n as absolute; busybox renice treats -n as an
# increment - the readback detects which one we got and retries accordingly.
tcorr_set_nice() {
    local tgid=$1 tid=$2 target=$3 cur new
    case "$target" in ''|*[!0-9-]*) return 1 ;; esac
    [ "$target" -lt -20 ] 2>/dev/null && target=-20
    [ "$target" -gt 19 ] 2>/dev/null && target=19
    renice -n "$target" -p "$tid" > /dev/null 2>&1 || return 1
    new=$(tcorr_read_nice "$tgid" "$tid")
    [ "$new" = "$target" ] && return 0
    [ -z "$new" ] && return 1
    renice -n "$((target - new))" -p "$tid" > /dev/null 2>&1 || return 1
    new=$(tcorr_read_nice "$tgid" "$tid")
    [ "$new" = "$target" ]
}

# Query predicted followers for the given trigger names.
# Usage: tcorr_predict <pkg> <file-with-one-trigger-name-per-line>
# Output: target|trigger|share%  (one per line)
tcorr_predict() {
    local pkg=$1 trig=$2
    [ -f "$TCORR_DB" ] || return
    [ -s "$trig" ] || return
    awk -F'|' -v pkg="$pkg" -v ms="$TP_TCORR_MIN_SAMPLES" -v msh="$TP_TCORR_MIN_SHARE" -v bl="$TP_BLACKLIST" '
        FNR == 1 { f++ }
        f == 1 { tr[$0] = 1; next }                          # trigger names
        f == 2 { if ($1 == pkg && $3 == "*") den[$2] = $4; next }   # pass 1: denominators
        f == 3 {
            if ($1 != pkg || $3 == "*" || !(($2) in tr)) next
            d = den[$2]; if (d < ms) next
            if ($3 ~ bl) next                                # blacklisted name
            if ($4 * 100 < msh * d) next
            print $3 "|" $2 "|" int($4 * 100 / d)
        }' "$trig" "$TCORR_DB" "$TCORR_DB" 2>/dev/null
}

# Batch-merge one cycle's observations into thread_corr.db (ONE awk rewrite).
# $1=pkg $2=triggers file (names hot within the window) $3=hot-now file $4=now
tcorr_update_db() {
    local pkg=$1 trig=$2 hot=$3 now=$4
    [ -s "$hot" ] || return
    [ -f "$TCORR_DB" ] || touch "$TCORR_DB" 2>/dev/null
    [ -f "$TCORR_DB" ] || return
    chmod 0644 "$TCORR_DB" 2>/dev/null
    local tmp="${TCORR_DB}.tmp.$$"
    awk -F'|' -v OFS='|' -v pkg="$pkg" -v now="$now" '
        FNR == 1 { f++ }
        f == 1 { tr[$0] = 1; next }                  # triggers (window)
        f == 2 { tg[$0] = 1; next }                  # hot now
        f == 3 {
            if ($1 != pkg) { print; next }
            if ($3 == "*") {
                if (($2) in tg) { $4 += 1; $5 = now }        # A was hot: denominator
                seenD[$2] = 1
            } else {
                if ($2 != $3 && (($2) in tr) && (($3) in tg)) { $4 += 1; $5 = now }
                seenP[$2 SUBSEP $3] = 1
            }
            print
            next
        }
        END {
            for (a in tg)
                if (!((a) in seenD)) printf "%s|%s|*|1|%s\n", pkg, a, now
            for (a in tr)
                for (b in tg)
                    if (a != b && !((a SUBSEP b) in seenP))
                        printf "%s|%s|%s|1|%s\n", pkg, a, b, now
        }' "$trig" "$hot" "$TCORR_DB" > "$tmp" 2>/dev/null && mv "$tmp" "$TCORR_DB" 2>/dev/null
    # Cap the DB (drop least-recently-seen entries)
    local lines=$(wc -l < "$TCORR_DB" 2>/dev/null)
    case "$lines" in ''|*[!0-9]*) return ;; esac
    [ "$lines" -le 1000 ] && return
    sort -t'|' -k5,5 -rn "$TCORR_DB" 2>/dev/null | head -n 700 > "$tmp" \
        && mv "$tmp" "$TCORR_DB" 2>/dev/null
    log_msg "[TCORR] thread_corr.db pruned ($lines -> 700 entries)"
}

# Restore every correlation-boosted thread's original nice and clear state.
tcorr_release_all() {
    local reason=${1:-unknown}
    [ -f "$TCORR_STATE" ] || return 0
    local tag tid tgid start name orig trigger misses restored=0
    while IFS='|' read -r tag tid tgid start name orig trigger misses; do
        [ "$tag" = "CORS" ] || continue
        if [ -d "/proc/$tgid/task/$tid" ]; then
            tcorr_set_nice "$tgid" "$tid" "$orig" && restored=$((restored + 1))
        fi
    done < "$TCORR_STATE"
    rm -f "$TCORR_STATE" 2>/dev/null
    [ "$restored" -gt 0 ] && log_msg "[TCORR] Restored $restored boosted thread(s) ($reason)"
    return 0
}

# Smart per-thread affinity: sample every thread of the foreground app, pin
# the sustained-hot ones to the big cluster (elastic 2->3 budget), leave the
# rest on the mode's learned whole-app mask. taskset is invoked ONLY for
# threads whose target mask changed since last cycle.
#
# On top of the classic hot-pinning this function implements:
#  - SELF-MANAGEMENT DETECTION (observe -> monitor/manage): apps that place
#    their own hot threads on big cores are left alone (sample-only); a heavy
#    thread stranded off the big cluster revokes that instantly. Verdicts
#    persist 7 days in config/selfmanage.db.
#  - MASK READ-BACK: the kernel's actual affinity is compared against our
#    bookkeeping every cycle for pinned threads; an app that silently
#    overwrites our pins gets them re-asserted (and the event is counted).
#  - ORIGINAL-MASK RESTORE: a thread's pre-touch mask is recorded once and
#    restored on release - the app's own affinity choices survive us.
#  - KEEPER DISPLACEMENT: pinned threads must defend their slot by load; a
#    candidate displace_margin points hotter (or any hot candidate, when the
#    keeper idles below release_threshold) takes the slot.
#  - LIVE-LOAD FALLBACK: with too few learning samples the coarse mask comes
#    from this cycle's measured load instead of a blind 0xff.
# Cold-thread mask splitter: narrows the coarse whole-app mask for one
# UNPINNED thread by the thread's own live CPU%. Result in COLD_MASK (a
# global, so the per-thread call stays fork-free even on mksh, which lacks
# "printf -v"; the value table covers every ladder shape get_affinity_mask
# can produce: 01/03/07/0f/1f/3f).
# Tiers (defaults in parentheses, cold_*_mask_cpu in thread_pin.conf):
#   cpu >= TP_COLD_FULL (20) -> full coarse mask, big-core bits included:
#                               the ONLY way an unpinned thread may still
#                               reach cpu6-7 (near-hot, one tier below the
#                               pin threshold; the learning engine's big
#                               gates decided whether those bits exist).
#   cpu >= TP_COLD_WIDE  (8) -> coarse mask's little-cluster portion
#   cpu >= TP_COLD_MID   (3) -> cpu0-3 (intersected with the coarse mask)
#   else                     -> cpu0-1 (intersected with the coarse mask)
COLD_MASK="3f"
cold_thread_mask() {
    local cpu=$1 coarse=$2
    case "$cpu" in ''|*[!0-9]*) cpu=0 ;; esac
    case "$coarse" in ''|*[!0-9a-f]*) coarse="3f" ;; esac
    local cval=$((0x$coarse))
    local lbits=$((cval & 0x3f))
    if [ "$lbits" -eq 0 ]; then COLD_MASK=$coarse; return; fi
    if [ "$cpu" -ge "$TP_COLD_FULL" ]; then COLD_MASK=$coarse; return; fi
    local m
    if [ "$cpu" -ge "$TP_COLD_WIDE" ]; then
        m=$lbits
    elif [ "$cpu" -ge "$TP_COLD_MID" ]; then
        m=$((lbits & 0x0f)); [ "$m" -eq 0 ] && m=$lbits
    else
        m=$((lbits & 0x03)); [ "$m" -eq 0 ] && m=$((lbits & 0x0f)); [ "$m" -eq 0 ] && m=$lbits
    fi
    case "$m" in
        1)  COLD_MASK="01" ;; 3)  COLD_MASK="03" ;; 7)  COLD_MASK="07" ;;
        15) COLD_MASK="0f" ;; 31) COLD_MASK="1f" ;; 63) COLD_MASK="3f" ;;
        *)  COLD_MASK="3f" ;;   # non-ladder shape (unreachable today): stay little-only
    esac
}

apply_app_affinity_smart() {
    local pkg=$1
    local mode=$2
    local OLD_IFS=$IFS

    local temp=$(get_temperature)
    local coarse=$(get_affinity_mask "$pkg" "$mode")
    local big_mask=$TP_BIG_MASK

    # Hard thermal release: drop all pins, apply the plain mask, done.
    if [ "$temp" -ge "$TP_REL_TEMP" ] 2>/dev/null; then
        release_all_pins "ff" "temp ${temp}C >= ${TP_REL_TEMP}C"
        tcorr_release_all "temp ${temp}C >= ${TP_REL_TEMP}C"
        apply_app_affinity_legacy "$pkg" "$mode"
        return
    fi

    local now=$(date +%s)

    # ---- v3.3: 模型分数 (权重式干扰, 不硬替换规则) ----
    local nn_scores="" nn_ok=0 nn_top=0.0 nn_smooth=1.0
    if [ "$TP_NN_MANAGE" = "true" ] && [ -f "$MODDIR/model/mlp_v3_enc.txt" ] && [ -f "$MODDIR/model/mlp_v3_scr.txt" ]; then
        nn_scores=$(sh "$MODDIR/bin/nn_infer_v3.sh" 2>/dev/null)
        case "$nn_scores" in
            *\|*)
                nn_ok=1
                nn_top=$(printf '%s\n' "$nn_scores" | grep -v '^K=' | awk -F'|' '{if($3+0>m)m=$3+0} END{printf "%.3f", m+0}')
                nn_smooth=$(printf '%s\n' "$nn_scores" | sed -n 's/^K=.* SMOOTH=\([0-9.]*\).*/\1/p' | head -1)
                case "$nn_smooth" in ''|*[!0-9.]*) nn_smooth=1.0 ;; esac
                ;;
            *) nn_ok=0 ;;
        esac
    fi

    # ---- previous cycle state (TID lines cached in TP_S_<tid> vars) ----
    local s_pkg="" s_exp=0 s_expanded=0 s_con=0
    local prev_tids=""
    local tag f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12
    if [ -f "$TPIN_STATE" ]; then
        while IFS='|' read -r tag f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12; do
            case "$tag" in
                PKG) s_pkg=$f2; s_exp=$f3; s_expanded=$f4; s_con=$f5 ;;
                TID)
                    # all-numeric payload -> eval-safe
                    # fields: tgid|start|jiffies|ts|cpu|hot_s|cold_s|target|applied|orig
                    eval "TP_S_$f2=\"$f3|$f4|$f5|$f6|$f7|$f8|$f9|$f10|$f11|$f12\""
                    prev_tids="$prev_tids $f2"
                    ;;
            esac
        done < "$TPIN_STATE"
    fi
    case "$s_exp" in ''|*[!0-9]*) s_exp=0 ;; esac
    case "$s_expanded" in ''|*[!01]*) s_expanded=0 ;; esac
    case "$s_con" in ''|*[!0-9]*) s_con=0 ;; esac

    # ---- app switched: unpin the old app's threads, start fresh ----
    if [ -n "$s_pkg" ] && [ "$s_pkg" != "$pkg" ]; then
        release_all_pins "ff" "app switch $s_pkg -> $pkg"
        tcorr_release_all "app switch $s_pkg -> $pkg"
        s_exp=0; s_expanded=0; s_con=0
    fi

    # ---- learned-hot names for this app (Phase 2) + manual pin_names ----
    local learned_nl=""
    if [ "$TP_TLEARN" = "true" ] && [ -f "$THREAD_LEARN_DB" ]; then
        learned_nl=$(awk -F'|' -v pkg="$pkg" -v ms="$TP_TLEARN_MIN_SAMPLES" -v msh="$TP_TLEARN_MIN_SHARE" \
            '$1 == pkg && $3 >= ms && ($5 * 100 / $3) >= msh {print $2}' "$THREAD_LEARN_DB" 2>/dev/null)
    fi
    # tr, not ${var//,/ }: the bash-only expansion breaks on dash-likes.
    local pn_list=$(echo "$TP_PIN_NAMES" | tr ',' ' ')

    # ---- correlation prediction: which threads tend to follow the hot ones ----
    # Uses the hot-name history from PREVIOUS cycles, so this is a genuine
    # prediction; learning for the CURRENT cycle happens after pass 2.
    local corr_names="" corr_pred="" hot_names="" live_nl=""
    local trig_f="$TCORR_HIST.trig.$$" hot_f="$TCORR_HIST.hot.$$" all_f="$TCORR_HIST.all.$$"
    : > "$trig_f" 2>/dev/null
    if [ "$TP_TCORR" = "true" ]; then
        # prune history to the observation window, collect distinct names
        if [ -f "$TCORR_HIST" ]; then
            local hts hname kept="" recents=""
            while IFS='|' read -r hts hname; do
                case "$hts" in ''|*[!0-9]*) continue ;; esac
                [ -z "$hname" ] && continue
                [ "$hts" -lt $((now - TP_TCORR_WIN)) ] 2>/dev/null && continue
                kept="${kept}${hts}|${hname}
"
                case "
$recents
" in
                    *"
$hname
"*) ;;
                    *) recents="${recents}${hname}
" ;;
                esac
            done < "$TCORR_HIST"
            printf '%s' "$kept" > "$TCORR_HIST" 2>/dev/null
            printf '%s' "$recents" > "$trig_f" 2>/dev/null
        fi
        if [ -s "$trig_f" ]; then
            corr_pred=$(tcorr_predict "$pkg" "$trig_f")
            [ -n "$corr_pred" ] && corr_names=$(printf '%s\n' "$corr_pred" | cut -d'|' -f1)
        fi
    fi

    # ---- pass 1: sample every thread, classify, update streaks ----
    local pids=$(get_app_pids "$pkg")
    # App process gone: drop stale state so the next app (or its own
    # restart) never inherits dead bookkeeping.
    if [ -z "$pids" ]; then
        rm -f "$trig_f" 2>/dev/null
        [ "$s_pkg" = "$pkg" ] && rm -f "$TPIN_STATE" 2>/dev/null
        return
    fi

    local top1=0 top2=0 top3=0
    local live_tids=""
    local cand_list="" n_cand=0
    local keep_list="" n_keep=0
    local bl_pool=""          # v3.3: 小核均衡候选池 tid|score|cpu
    local learn_updates=""
    local hot_list="" app_load=0
    local pid tp tid comm statline rest u s j_cur st_cur
    local cpu hot_s cold_s prev_target prev_applied prev_orig stline
    local blacklisted learned bl pn
    local o_tgid o_start o_j o_ts o_hs o_cs elapsed delta

    for pid in $pids; do
        [ -d "/proc/$pid/task" ] || continue
        for tp in /proc/$pid/task/[0-9]*; do
            [ -d "$tp" ] || continue
            tid=${tp##*/}

            statline=""
            IFS= read -r statline < "$tp/stat" 2>/dev/null
            [ -n "$statline" ] || continue
            # ${var##*)} strips through the LAST ')', so a comm containing
            # parens cannot shift the field positions (utime/stime = 12/13,
            # starttime = 20 of the remainder).
            rest=${statline##*)}
            set -- $rest
            u=${12:-0}; s=${13:-0}; st_cur=${20:-0}
            case "$u$s" in ''|*[!0-9]*) continue ;; esac
            case "$st_cur" in ''|*[!0-9]*) continue ;; esac
            j_cur=$((u + s))
            comm=""
            IFS= read -r comm < "$tp/comm" 2>/dev/null

            # per-thread instantaneous CPU% (jiffies delta; 100/s = one core)
            cpu=0; hot_s=0; cold_s=0; prev_target=""; prev_applied=""; prev_orig=""
            eval "stline=\$TP_S_$tid"
            if [ -n "$stline" ]; then
                IFS='|'
                set -- $stline
                IFS=$OLD_IFS
                o_tgid=$1; o_start=$2; o_j=$3; o_ts=$4; o_hs=$6; o_cs=$7
                # TID-reuse guard: same tid, same process, same start time.
                # prev_target/prev_applied are trusted ONLY inside this guard:
                # a recycled TID must not inherit the dead thread's pin state
                # (it used to stay "pinned" in the state file for up to
                # release_streak cycles without any taskset ever touching it).
                if [ "$o_tgid" = "$pid" ] && [ "$o_start" = "$st_cur" ]; then
                    prev_target=$8; prev_applied=$9; prev_orig=${10}
                    case "$o_j$o_ts" in
                        ''|*[!0-9]*) ;;
                        *)
                            elapsed=$((now - o_ts))
                            delta=$((j_cur - o_j))
                            if [ "$elapsed" -gt 0 ] && [ "$delta" -ge 0 ]; then
                                cpu=$((delta / elapsed))
                                [ "$cpu" -gt 100 ] && cpu=100
                            fi
                            hot_s=$o_hs; cold_s=$o_cs
                            ;;
                    esac
                fi
            fi
            case "$hot_s" in ''|*[!0-9]*) hot_s=0 ;; esac
            case "$cold_s" in ''|*[!0-9]*) cold_s=0 ;; esac

            # Hysteresis band: >=hot accumulates, <=release decays, the band
            # between resets both (a pinned thread holding in the band keeps
            # its pin; an unpinned one must prove itself again).
            if [ "$cpu" -ge "$TP_HOT" ]; then
                hot_s=$((hot_s + 1)); cold_s=0
            elif [ "$cpu" -le "$TP_REL" ]; then
                cold_s=$((cold_s + 1)); hot_s=0
            else
                hot_s=0; cold_s=0
            fi

            # Name blacklist: never pinned, never learned, invisible to the
            # elastic trigger.
            blacklisted=0
            IFS='|'
            for bl in $TP_BLACKLIST; do
                case "$comm" in *"$bl"*) blacklisted=1; break ;;
            esac
            done
            IFS=$OLD_IFS

            # Learned-hot / manual-name instant qualification
            learned=0
            if [ "$blacklisted" = 0 ]; then
                if [ -n "$learned_nl" ]; then
                    case "
$learned_nl
" in
                        *"
$comm
"*) learned=1 ;;
                    esac
                fi
                if [ "$learned" = 0 ] && [ -n "$pn_list" ]; then
                    for pn in $pn_list; do
                        if [ "$comm" = "$pn" ]; then
                            learned=1
                            break
                        fi
                    done
                fi
                # Correlation-predicted followers skip the hot_streak wait and
                # compete for a pin slot right away (still bounded by the
                # elastic budget, and ranked by their current CPU%).
                if [ "$learned" = 0 ] && [ "$TP_TCORR" = "true" ] && \
                   [ "$TP_TCORR_PIN" = "true" ] && [ -n "$corr_names" ]; then
                    case "
$corr_names
" in
                        *"
$comm
"*) learned=1 ;;
                    esac
                fi
            fi

            # Elastic trigger statistics (eligible threads only)
            if [ "$blacklisted" = 0 ]; then
                if [ "$cpu" -gt "$top1" ]; then
                    top3=$top2; top2=$top1; top1=$cpu
                elif [ "$cpu" -gt "$top2" ]; then
                    top3=$top2; top2=$cpu
                elif [ "$cpu" -gt "$top3" ]; then
                    top3=$cpu
                fi
                # hot inventory for the self-management assessment:
                # cpu|tid|tgid|mask-we-applied ("" = mask is the app's own)
                [ "$cpu" -ge "$TP_HOT" ] && hot_list="${hot_list}${cpu}|${tid}|${pid}|${prev_applied}
"
            fi
            app_load=$((app_load + cpu))

            # Keep / candidate classification (v3.3: 模型分数加权)
            # 行格式 cpu|eff|tid; eff=负载+模型偏移(±nn_max_adjust), 排序用 eff
            local nn_adj=0
            local bl_meta=""
            if [ "$nn_ok" = 1 ]; then
                local nns=0.5
                nns=$(printf '%s\n' "$nn_scores" | awk -F'|' -v n="$comm" '$1==n {print $3; exit}')
                case "$nns" in ''|*[!0-9.]*) nns=0.5 ;; esac
                nn_adj=$(awk "BEGIN{a=($nns-0.5)*2*$TP_NN_MAX_ADJ; if(a>$TP_NN_MAX_ADJ)a=$TP_NN_MAX_ADJ; if(a< -$TP_NN_MAX_ADJ)a= -$TP_NN_MAX_ADJ; printf \"%d\", a}")
                bl_meta="${tid}|${nns}|${cpu}"
            fi
            local eff=$((cpu + nn_adj))
            [ "$eff" -lt 0 ] && eff=0
            [ "$eff" -gt 100 ] && eff=100
            if [ "$blacklisted" = 0 ]; then
                [ -n "$bl_meta" ] && bl_pool="${bl_pool}${bl_meta}
"
                if [ "$prev_target" = "$big_mask" ]; then
                    # pinned last cycle: keep unless it went cold for good
                    if [ "$cold_s" -lt "$TP_REL_STREAK" ]; then
                        keep_list="${keep_list}${cpu}|${eff}|${tid}
"
                        n_keep=$((n_keep + 1))
                    fi
                elif { [ "$hot_s" -ge "$TP_HOT_STREAK" ] || [ "$learned" = 1 ]; } && \
                     [ "$cold_s" -lt "$TP_REL_STREAK" ]; then
                    cand_list="${cand_list}${cpu}|${eff}|${tid}
"
                    n_cand=$((n_cand + 1))
                fi
            fi

            # Phase 2 recording: only threads with real load
            if [ "$TP_TLEARN" = "true" ] && [ "$blacklisted" = 0 ] && \
               [ "$cpu" -ge "$TP_TLEARN_MIN_CPU" ] && [ -n "$comm" ]; then
                case "$comm" in
                    *'|'*) ;;
                    *) learn_updates="${learn_updates}${comm}|${cpu}
" ;;
                esac
            fi

            # Correlation engine sampling: live inventory + this cycle's hot
            # names (consumed after pass 2 for pair learning and boost
            # target resolution).
            if [ "$TP_TCORR" = "true" ] && [ "$blacklisted" = 0 ]; then
                case "$comm" in
                    ''|*'|'*) ;;
                    *)
                        live_nl="${live_nl}${tid}|${pid}|${st_cur}|${comm}
"
                        if [ "$cpu" -ge "$TP_HOT" ]; then
                            case "
$hot_names
" in
                                *"
$comm
"*) ;;
                                *) hot_names="${hot_names}${comm}
" ;;
                            esac
                        fi
                        ;;
                esac
            fi

            # remember this cycle's values for the apply pass (all numeric)
            eval "TP_N_$tid=\"$pid|$st_cur|$j_cur|$cpu|$hot_s|$cold_s|$prev_target|$prev_applied|$prev_orig\""
            live_tids="$live_tids $tid"
        done
    done

    # ================= self-management assessment =================
    # Judges what the app does WITH ITS OWN affinity settings (masks NOT made
    # by us), purely from live data - no prediction history needed:
    #   observe - unknown app: withhold ALL affinity ops for a bounded number
    #             of cycles and watch where the app itself puts hot threads;
    #   monitor - the app provably places its own hot threads on restricted
    #             big-core-inclusive masks: hands off, watch only. A heavy
    #             thread (>= intervene_cpu) stranded on a big-core-less or
    #             all-core mask for intervene_streak cycles REVOKES the
    #             excellence and management resumes in the same cycle;
    #   manage  - normal engine behavior (pins, coarse mask, boosts).
    # A 60% thread left on 0-7 (the classic badly-optimized game pattern)
    # fails the check instantly; it can never be classified excellent.
    local sm_mode="manage"
    local sm_exc=0 sm_good=0 sm_bad=0 sm_int=0 sm_obs=0 sm_ext=0 sm_pkg=""
    if [ "$TP_SELFM" = "true" ]; then
        if [ -f "$SELFM_STATE" ]; then
            IFS='|' read -r sm_pkg sm_exc sm_good sm_bad sm_int sm_obs sm_ext < "$SELFM_STATE" 2>/dev/null
        fi
        case "$sm_exc" in ''|*[!01]*) sm_exc=0 ;; esac
        case "$sm_good" in ''|*[!0-9]*) sm_good=0 ;; esac
        case "$sm_bad" in ''|*[!0-9]*) sm_bad=0 ;; esac
        case "$sm_int" in ''|*[!0-9]*) sm_int=0 ;; esac
        case "$sm_obs" in ''|*[!0-9]*) sm_obs=0 ;; esac
        case "$sm_ext" in ''|*[!0-9]*) sm_ext=0 ;; esac
        [ "$sm_pkg" != "$pkg" ] && { sm_exc=0; sm_good=0; sm_bad=0; sm_int=0; sm_obs=0; sm_ext=0; }
        # Evaluate ONLY masks we did not make: a mask equal to what we applied
        # carries no information about the app's own choices.
        local hl hcpu hrest htid htgid happ hm
        local hotn=0 sm_now=1 int_now=0
        for hl in $hot_list; do
            hcpu=${hl%%|*}; hrest=${hl#*|}
            htid=${hrest%%|*}; hrest=${hrest#*|}
            htgid=${hrest%%|*}; happ=${hrest#*|}
            hm=$(read_tid_mask_hex "$htgid" "$htid")
            [ -z "$hm" ] && continue
            [ -n "$happ" ] && [ "$hm" = "$happ" ] && continue
            hotn=$((hotn + 1))
            # good placement = restricted (not all 8 cores) AND big-inclusive
            if [ "$hm" = "ff" ] || [ $((0x$hm & 0xc0)) -eq 0 ] 2>/dev/null; then
                sm_now=0
                [ "$hcpu" -ge "$TP_SELFM_INT_CPU" ] && int_now=1
            fi
        done
        local verdict="" vts=0 vraw
        vraw=$(selfm_get_verdict "$pkg")
        verdict=${vraw%%|*}; vts=${vraw##*|}
        case "$vts" in ''|*[!0-9]*) vts=0 ;; esac
        # verdicts age out after 7 days: an app update may completely change
        # its thread behavior, so stale verdicts are re-observed
        if [ -n "$verdict" ] && [ $((now - vts)) -gt 604800 ]; then
            verdict=""
        fi
        if [ "$sm_exc" = 1 ] || [ "$verdict" = "excellent" ]; then
            sm_exc=1
            sm_mode="monitor"
            if [ "$int_now" = 1 ]; then sm_int=$((sm_int + 1)); else sm_int=0; fi
            if [ "$sm_int" -ge "$TP_SELFM_INT_STREAK" ]; then
                sm_exc=0; sm_good=0; sm_int=0
                sm_mode="manage"
                [ "$verdict" != "bad" ] && selfm_set_verdict "$pkg" "bad"
                log_msg "[SELFM] $pkg: thread >=${TP_SELFM_INT_CPU}% stuck off big cores for $TP_SELFM_INT_STREAK cycle(s) - excellence REVOKED, taking over"
            fi
        elif [ "$verdict" = "bad" ]; then
            sm_mode="manage"        # known badly-optimized app: act at once
        else
            sm_obs=$((sm_obs + 1))
            sm_mode="observe"
            if [ "$hotn" -gt 0 ]; then
                if [ "$sm_now" = 1 ]; then
                    sm_good=$((sm_good + 1))
                else
                    sm_good=0
                    if [ "$int_now" = 1 ]; then
                        # heavy thread free-range / little-only: definitively
                        # NOT excellent - stop watching, start managing
                        sm_mode="manage"; sm_obs=0
                        selfm_set_verdict "$pkg" "bad"
                        log_msg "[SELFM] $pkg: hot thread (>=${TP_SELFM_INT_CPU}%) on wrong cores - not self-managed, engine takes over"
                    fi
                fi
                if [ "$sm_mode" = "observe" ] && [ "$sm_good" -ge "$TP_SELFM_STREAK" ]; then
                    sm_exc=1; sm_mode="monitor"
                    selfm_set_verdict "$pkg" "excellent"
                    log_msg "[SELFM] $pkg: app places its own hot threads on big cores - EXCELLENT, monitor-only"
                    release_all_pins "" "self-managed app $pkg"
                    tcorr_release_all "self-managed app $pkg"
                fi
            fi
            # quiet/light app: nothing to judge within the window -> manage
            [ "$sm_mode" = "observe" ] && [ "$sm_obs" -ge "$TP_SELFM_OBS_MAX" ] && sm_mode="manage"
        fi
    fi

    # ---- load-based fallback coarse mask -------------------------------
    # With too few learning samples the classic engine left the app at
    # 0xff ("don't restrict what you don't know") and simply never adjusted.
    # (v1.5.3) The fallback ceiling is the full little cluster in EVERY mode
    # (get_affinity_mask's no-data default is 0x3f as well; this branch just
    # makes it explicit). The per-thread cold splitter below then narrows
    # each unpinned thread by its OWN live load, and hot threads are still
    # promoted to the A76s by the pins above - so an unknown app is neither
    # blind nor allowed to leak cold threads onto cpu6-7.
    if [ "$mode" != "ultra" ] && [ "$mode" != "powersave" ]; then
        local lcnt2=0
        [ -f "$LEARNING_DB" ] && lcnt2=$(awk -F'|' -v pkg="$pkg" '$1 == pkg {print $2; exit}' "$LEARNING_DB" 2>/dev/null)
        case "$lcnt2" in ''|*[!0-9]*) lcnt2=0 ;; esac
        if [ "$lcnt2" -lt "$TP_MASK_MIN_SAMPLES" ]; then
            coarse="3f"
        fi
    fi

    # ---- elastic budget: 2 slots normally, 3 while a third heavy thread ----
    # ---- proves both A76s are saturated and thermals have headroom      ----
    # (meaningful only while managing; in observe/monitor mode nothing is
    # pinned, so skip the trigger bookkeeping and its log spam)
    local pair=$((top1 + top2))
    # v3.3: escalate(2->3) 需模型认可 (模型最高分>=门槛 且 场景卡顿) 才允许
    local nn_esc_ok=1
    if [ "$TP_NN_ESC" = "true" ] && [ "$nn_ok" = 1 ]; then
        nn_esc_ok=0
        [ "$(awk "BEGIN{print ($nn_top >= $TP_NN_ESC_SCORE)?1:0}")" = 1 ] && \
        [ "$(awk "BEGIN{print ($nn_smooth <= $TP_NN_ESC_SMOOTH)?1:0}")" = 1 ] && nn_esc_ok=1
    fi
    if [ "$sm_mode" != "manage" ]; then
        :
    elif [ "$temp" -ge "$TP_ESC_TEMP" ]; then
        if [ "$s_expanded" = 1 ]; then
            s_expanded=0; s_exp=0; s_con=0
            log_msg "[TPIN] $pkg: big-core budget 3->2 (temp ${temp}C >= ${TP_ESC_TEMP}C)"
        fi
    elif [ "$top3" -ge "$TP_ESC_TH" ] && [ "$pair" -ge "$TP_ESC_PAIR" ] && [ "$nn_esc_ok" = 1 ]; then
        s_exp=$((s_exp + 1)); s_con=0
        if [ "$s_exp" -ge "$TP_ESC_STREAK" ] && [ "$s_expanded" = 0 ]; then
            s_expanded=1
            log_msg "[TPIN] $pkg: big-core budget 2->3 (3rd=${top3}% >= ${TP_ESC_TH}%, top2=${pair}% >= ${TP_ESC_PAIR}%)"
        fi
    elif [ "$top3" -le "$TP_REL" ]; then
        s_exp=0
        if [ "$s_expanded" = 1 ]; then
            s_con=$((s_con + 1))
            if [ "$s_con" -ge "$TP_REL_STREAK" ]; then
                s_expanded=0; s_con=0
                log_msg "[TPIN] $pkg: big-core budget 3->2 (third thread cooled)"
            fi
        fi
    else
        s_exp=0
    fi
    local cap=$TP_BASE_CAP
    [ "$s_expanded" = 1 ] && cap=$TP_MAX_CAP
    [ "$cap" -gt "$TP_MAX_CAP" ] && cap=$TP_MAX_CAP

    # ---- pick who gets the slots: keepers vs candidates, BY LOAD ----------
    # Old behavior: keepers held their slot unconditionally until they went
    # fully cold (<=release for release_streak cycles). A keeper idling in the
    # 16-24% hysteresis band kept its A76 FOREVER (its cold streak resets
    # every cycle), and with both slots held by lukewarm keepers a 60%+
    # candidate starved. Now a genuinely-hot candidate evicts the coolest
    # keeper when it is displace_margin points hotter (or the keeper is
    # currently below release_threshold). Small differences never displace,
    # so the hysteresis still prevents flapping.
    local big_tids=" "
    local kl kl2 ccpu lowest lowest_cpu rebuilt
    local hold_keep="" hold_cand="" n_hold=0
    if [ "$sm_mode" = "manage" ]; then
        if [ "$n_keep" -gt 1 ]; then
            keep_list=$(printf '%s' "$keep_list" | sort -t'|' -k2,2 -rn)   # v3.3: eff 排序
        fi
        if [ "$n_keep" -gt "$cap" ]; then
            keep_list=$(printf '%s' "$keep_list" | head -n "$cap")
            n_keep=$cap
        fi
        for kl in $keep_list; do
            hold_keep="${hold_keep}${kl}
"
            n_hold=$((n_hold + 1))
        done
        if [ "$n_cand" -gt 1 ]; then
            cand_list=$(printf '%s' "$cand_list" | sort -t'|' -k2,2 -rn)   # v3.3: eff 排序
        fi
        for kl in $cand_list; do
            ccpu=${kl%%|*}
            case "$ccpu" in ''|*[!0-9]*) continue ;; esac
            if [ "$n_hold" -lt "$cap" ]; then
                hold_cand="${hold_cand}${kl}
"
                n_hold=$((n_hold + 1))
                continue
            fi
            [ -z "$hold_keep" ] && break
            lowest=""; for kl2 in $hold_keep; do lowest=$kl2; done
            lowest_cpu=${lowest%%|*}
            case "$lowest_cpu" in ''|*[!0-9]*) break ;; esac
            if [ "$ccpu" -ge "$TP_HOT" ] && \
               { [ "$lowest_cpu" -lt "$TP_REL" ] || [ "$ccpu" -ge $((lowest_cpu + TP_DISPLACE)) ]; }; then
                rebuilt=""
                for kl2 in $hold_keep; do
                    [ "$kl2" = "$lowest" ] || rebuilt="${rebuilt}${kl2}
"
                done
                hold_keep=$rebuilt
                n_keep=$((n_keep - 1))
                hold_cand="${hold_cand}${kl}
"
                log_msg "[TPIN] Displace tid=${lowest##*|} (${lowest_cpu}%) from big-core slot by hotter tid=${kl##*|} (${ccpu}%) [$pkg]"
            else
                break   # remaining candidates are even cooler
            fi
        done
        for kl in $hold_keep $hold_cand; do big_tids="${big_tids}${kl##*|} "; done
    fi

    # ---- v3.3: 小核均衡分配器 ----
    # 模型分数前 N 名的未绑线程, least-loaded 分配到 cpu0-5 (让每个小核负载趋均)
    # 折中策略: 只重排高分前 N 名, 其余保持 COLD_MASK 不动, 避免线程频繁跳动
    local little_plan=""
    if [ "$TP_NN_BALANCE" = "true" ] && [ "$nn_ok" = 1 ] && [ "$sm_mode" = "manage" ] && [ -n "$bl_pool" ]; then
        local pl_cands="" pl_line pl_tid pl_s pl_c
        for pl_line in $bl_pool; do
            pl_tid=${pl_line%%|*}; pl_rest=${pl_line#*|}; pl_s=${pl_rest%%|*}; pl_c=${pl_rest##*|}
            case "$big_tids" in
                *" $pl_tid "*) ;;
                *) pl_cands="${pl_cands}${pl_s}|${pl_tid}
" ;;
            esac
        done
        pl_cands=$(printf '%b' "$pl_cands" | sort -t'|' -k1,1 -rn | head -n "$TP_NN_BALANCE_TOP")
        if [ -n "$pl_cands" ]; then
            local cl0=0 cl1=0 cl2=0 cl3=0 cl4=0 cl5=0 cl6=0 cl7=0
            IFS='|' read -r cl0 cl1 cl2 cl3 cl4 cl5 cl6 cl7 < "$CORE_LOAD_FILE" 2>/dev/null
            case "$cl0$cl1$cl2$cl3$cl4$cl5" in ''|*[!0-9]*) cl0=0; cl1=0; cl2=0; cl3=0; cl4=0; cl5=0 ;; esac
            local l0=$cl0 l1=$cl1 l2=$cl2 l3=$cl3 l4=$cl4 l5=$cl5
            local pl2 pl_best_v pl_best_n pl_maskhex pl_tid2 pl_s2
            for pl2 in $pl_cands; do
                pl_s2=${pl2%%|*}; pl_tid2=${pl2##*|}
                pl_best_v=$l0; pl_best_n=0
                [ "$l1" -lt "$pl_best_v" ] && { pl_best_v=$l1; pl_best_n=1; }
                [ "$l2" -lt "$pl_best_v" ] && { pl_best_v=$l2; pl_best_n=2; }
                [ "$l3" -lt "$pl_best_v" ] && { pl_best_v=$l3; pl_best_n=3; }
                [ "$l4" -lt "$pl_best_v" ] && { pl_best_v=$l4; pl_best_n=4; }
                [ "$l5" -lt "$pl_best_v" ] && { pl_best_v=$l5; pl_best_n=5; }
                pl_maskhex=$(printf '%x' $((1 << pl_best_n)))
                little_plan="${little_plan}${pl_tid2}|${pl_maskhex}
"
                # 占位: 该核负载 +20, 防多个高分线程挤同一核
                case "$pl_best_n" in
                    0) l0=$((l0 + 20)) ;; 1) l1=$((l1 + 20)) ;;
                    2) l2=$((l2 + 20)) ;; 3) l3=$((l3 + 20)) ;;
                    4) l4=$((l4 + 20)) ;; 5) l5=$((l5 + 20)) ;;
                esac
            done
        fi
    fi

    # ---- pass 2: apply --------------------------------------------------
    # taskset runs only for threads whose target changed. In observe/monitor
    # mode (self-managed apps) NOTHING is applied - we only keep the sampling
    # state alive. Every bind goes through aff_bind_tid (normalized mask,
    # multi-method, kernel read-back verification, logged failures).
    #
    # FAILURE SURVIVAL: a thread whose bind failed is KEPT in the state file
    # with applied="" (the old code dropped it with 'continue', which reset
    # its sampling streaks - one failed taskset meant the thread never
    # qualified again and pinning died silently). Keeping it means the bind
    # is retried automatically on the next cycle.
    #
    # Read-back policy: pinned threads are verified against the kernel EVERY
    # cycle; coarse-masked threads every 5th cycle. An app (or another tool)
    # that overwrites our masks gets re-asserted instead of winning silently.
    local no_apply=0
    [ "$sm_mode" = "manage" ] || no_apply=1
    local ext_over=0 applied_n=0 fail_n=0 deferred_n=0
    local verify_cycle=0
    [ $((AFF_CYCLE % 5)) -eq 0 ] && verify_cycle=1
    local new_state="PKG|$pkg|$s_exp|$s_expanded|$s_con
"
    local tid2 stline2 target applied orig comm2 cur_mask
    for tid2 in $live_tids; do
        eval "stline2=\$TP_N_$tid2"
        [ -n "$stline2" ] || continue
        IFS='|'
        set -- $stline2
        IFS=$OLD_IFS
        # 1=tgid 2=starttime 3=jiffies 4=cpu 5=hot_s 6=cold_s 7=prev_target 8=prev_applied 9=prev_orig
        case "$big_tids" in
            *" $tid2 "*)
                target=$big_mask ;;
            *)
                # v3.3: 小核均衡计划命中 -> 绑计划核 (模型分数前N, least-loaded)
                if [ -n "$little_plan" ]; then
                    local plan_mask=""
                    plan_mask=$(printf '%b' "$little_plan" | awk -F'|' -v t="$tid2" '$1==t {print $2; exit}')
                    if [ -n "$plan_mask" ]; then
                        target=$plan_mask
                    else
                        # Unpinned thread: never the raw coarse mask - narrow it by
                        # this thread's OWN load (idle threads huddle on cpu0-1,
                        # busier ones spread over cpu0-5, only near-hot ones may use
                        # the coarse mask's big-core bits). fork-free via COLD_MASK.
                        cold_thread_mask "$4" "$coarse"
                        target=$COLD_MASK
                    fi
                else
                    cold_thread_mask "$4" "$coarse"
                    target=$COLD_MASK
                fi ;;
        esac
        applied=$8
        orig=$9
        if [ "$no_apply" = "1" ]; then
            target=""; applied=""     # hands-off: sample only, touch nothing
        elif [ "$target" != "$8" ]; then
            # read the KERNEL's mask first: a thread that died between passes
            # is dropped from state; a live thread is bound and verified
            cur_mask=$(aff_read_mask "$tid2")
            if [ -z "$cur_mask" ]; then
                continue   # thread died between passes; drop from state
            fi
            if [ -n "$8" ] && [ "$cur_mask" != "$8" ]; then
                ext_over=$((ext_over + 1))
                log_msg "[TPIN] External affinity change tid=$tid2: ours=0x$8 actual=0x$cur_mask [$pkg]"
            fi
            # capture the ORIGINAL mask once (before our first touch) so a
            # later release can restore the app's own setting exactly
            [ -z "$orig" ] && orig=$cur_mask
            if aff_bind_tid "$tid2" "$target" "TPIN $pkg"; then
                applied=$target
                applied_n=$((applied_n + 1))
                comm2=""
                IFS= read -r comm2 < "/proc/$1/task/$tid2/comm" 2>/dev/null
                if [ "$target" = "$big_mask" ]; then
                    log_msg "[TPIN] Pin tid=$tid2 ($comm2) cpu=$4% -> 0x$big_mask (verified) [$pkg]"
                elif [ "$8" = "$big_mask" ]; then
                    log_msg "[TPIN] Unpin tid=$tid2 ($comm2) cpu=$4% -> 0x$target (verified) [$pkg]"
                fi
            else
                applied=""              # bind failed: keep the state, retry next cycle
                case "$AFF_LAST" in
                    defer|clamped) deferred_n=$((deferred_n + 1)) ;;   # cpuset-blocked: retried anyway, but not a tool failure
                    *) fail_n=$((fail_n + 1)) ;;
                esac
            fi
        elif [ "$target" = "$big_mask" ]; then
            # pinned and state agrees: verify the KERNEL still agrees
            cur_mask=$(aff_read_mask "$tid2")
            if [ -n "$cur_mask" ] && [ "$cur_mask" != "$big_mask" ]; then
                ext_over=$((ext_over + 1))
                if aff_bind_tid "$tid2" "$big_mask" "TPIN $pkg"; then
                    applied_n=$((applied_n + 1))
                    log_msg "[TPIN] Pin tid=$tid2 externally reset to 0x$cur_mask, re-asserted 0x$big_mask (verified) [$pkg]"
                else
                    applied=""          # force a full re-bind next cycle
                    case "$AFF_LAST" in
                        defer|clamped) deferred_n=$((deferred_n + 1)) ;;
                        *) fail_n=$((fail_n + 1)) ;;
                    esac
                fi
            fi
        elif [ "$verify_cycle" = "1" ] && [ -n "$8" ]; then
            # coarse-mask steady state: periodic kernel read-back so an
            # external reset is corrected (fork-free check, bind only on drift)
            cur_mask=$(aff_read_mask "$tid2")
            if [ -n "$cur_mask" ] && [ "$cur_mask" != "$8" ]; then
                ext_over=$((ext_over + 1))
                if aff_bind_tid "$tid2" "$target" "TPIN $pkg"; then
                    applied_n=$((applied_n + 1))
                    log_msg "[TPIN] Re-asserted 0x$target on tid=$tid2 (externally reset to 0x$cur_mask) [$pkg]"
                else
                    applied=""          # force a full re-bind next cycle
                    case "$AFF_LAST" in
                        defer|clamped) deferred_n=$((deferred_n + 1)) ;;
                        *) fail_n=$((fail_n + 1)) ;;
                    esac
                fi
            fi
        fi
        new_state="${new_state}TID|$tid2|$1|$2|$3|$now|$4|$5|$6|$target|$applied|$orig
"
    done
    printf '%s' "$new_state" > "$TPIN_STATE" 2>/dev/null
    if [ "$applied_n" -gt 0 ] || [ "$fail_n" -gt 0 ] || [ "$deferred_n" -gt 0 ]; then
        local dtxt=""
        [ "$deferred_n" -gt 0 ] && dtxt=" deferred=$deferred_n(cpuset)"
        log_msg "[TPIN] $pkg: affinity cycle applied=$applied_n failed=$fail_n$dtxt (mode=$mode)"
    fi

    # persist the self-management session counters (+ external-override tally)
    if [ "$TP_SELFM" = "true" ]; then
        sm_ext=$((sm_ext + ext_over))
        echo "$pkg|$sm_exc|$sm_good|$sm_bad|$sm_int|$sm_obs|$sm_ext" > "$SELFM_STATE" 2>/dev/null
    fi

    # ---- Phase 2: record hot-ish threads into the name-learning DB ----
    if [ -n "$learn_updates" ]; then
        printf '%s' "$learn_updates" | while IFS='|' read -r lcomm lcpu; do
            [ -n "$lcomm" ] && tlearn_record "$pkg" "$lcomm" "$lcpu"
        done
        tlearn_prune
    fi

    # ---- correlation engine: learn (A->B), boost predicted, demote cooled ----
    if [ "$TP_TCORR" = "true" ]; then
        # 1. LEARN: append current hot names to the history window and merge
        #    this cycle's (trigger x follower) pairs into thread_corr.db.
        if [ -n "$hot_names" ]; then
            local hn hn_out=""
            local OLD2=$IFS
            IFS='
'
            for hn in $hot_names; do hn_out="${hn_out}${now}|${hn}
"; done
            IFS=$OLD2
            printf '%s' "$hn_out" >> "$TCORR_HIST" 2>/dev/null
            printf '%s' "$hot_names" > "$hot_f" 2>/dev/null
            awk '!seen[$0]++' "$trig_f" "$hot_f" 2>/dev/null > "$all_f"
            tcorr_update_db "$pkg" "$all_f" "$hot_f" "$now"
        fi
        rm -f "$trig_f" "$hot_f" "$all_f" 2>/dev/null

        # 2. BOOST / DEMOTE with persistent state (orig nice kept for restore)
        local ctag ctid ctgid cstart cname corig ctrig cmiss
        local st_pkg="" corr_e_tids=""
        if [ -f "$TCORR_STATE" ]; then
            while IFS='|' read -r ctag ctid ctgid cstart cname corig ctrig cmiss; do
                case "$ctag" in
                    PKG) st_pkg=$ctid ;;
                    CORS)
                        eval "TC_E_$ctid=\"$ctgid|$cstart|$cname|$corig|$ctrig|$cmiss\""
                        corr_e_tids="$corr_e_tids $ctid" ;;
                esac
            done < "$TCORR_STATE"
        fi
        # corr state tracks its own app (TPIN_STATE may already be gone)
        if [ -n "$st_pkg" ] && [ "$st_pkg" != "$pkg" ]; then
            tcorr_release_all "app switch $st_pkg -> $pkg"
            for ctid in $corr_e_tids; do unset "TC_E_$ctid"; done
            corr_e_tids=""
        fi

        local new_corr_state="" n_cors=0
        local pline ptarget ptmp ptrig lline l_tid l_tgid l_tmp l_start l_name eline orig tgt
        local OLD2=$IFS
        IFS='
'
        # ---- BOOST: apply to live tids of predicted follower names ----
        # (monitor/observe modes are strictly hands-off: no nice changes)
        if [ -n "$corr_pred" ] && [ "$sm_mode" = "manage" ]; then
            for pline in $corr_pred; do
                ptarget=${pline%%|*}; ptmp=${pline#*|}; ptrig=${ptmp%%|*}
                for lline in $live_nl; do
                    l_tid=${lline%%|*}; l_tmp=${lline#*|}; l_tgid=${l_tmp%%|*}
                    l_tmp=${l_tmp#*|}; l_start=${l_tmp%%|*}; l_name=${l_tmp#*|}
                    [ "$l_name" = "$ptarget" ] || continue
                    eval "eline=\$TC_E_$l_tid"
                    if [ -n "$eline" ]; then
                        case "$eline" in
                            "$l_tgid|$l_start|"*)
                                # already boosted: hold (reset cool-down miss count)
                                new_corr_state="${new_corr_state}CORS|$l_tid|${eline%|*}|0
"
                                n_cors=$((n_cors + 1))
                                unset "TC_E_$l_tid"
                                continue ;;
                        esac
                        unset "TC_E_$l_tid"   # recycled TID: drop stale entry
                    fi
                    [ "$TP_TCORR_NICE" = "0" ] && continue   # pin-candidate only
                    orig=$(tcorr_read_nice "$l_tgid" "$l_tid")
                    [ -z "$orig" ] && continue
                    tgt=$((orig + TP_TCORR_NICE))
                    [ "$tgt" -lt -20 ] && tgt=-20
                    [ "$tgt" -gt 19 ] && tgt=19
                    [ "$tgt" = "$orig" ] && continue
                    if tcorr_set_nice "$l_tgid" "$l_tid" "$tgt"; then
                        log_msg "[TCORR] Boost tid=$l_tid ($l_name) nice $orig -> $tgt (trigger: $ptrig) [$pkg]"
                        new_corr_state="${new_corr_state}CORS|$l_tid|$l_tgid|$l_start|$l_name|$orig|$ptrig|0
"
                        n_cors=$((n_cors + 1))
                    fi
                done
            done
        fi

        # corr_e_tids is SPACE-separated, so the newline-only IFS used by the
        # BOOST loops must end HERE: with IFS=<newline> the list below would
        # not split, the whole blob became one "tid", every eval missed, and
        # no boost was ever cooled down or restored.
        IFS=$OLD2

        # ---- DEMOTE: boosted but no longer predicted this cycle ----
        local e_tgid e_start e_name e_orig e_trig e_miss
        for ctid in $corr_e_tids; do
            eval "eline=\$TC_E_$ctid"
            [ -n "$eline" ] || continue       # refreshed above: already handled
            unset "TC_E_$ctid"
            e_tgid=${eline%%|*}; l_tmp=${eline#*|}
            e_start=${l_tmp%%|*}; l_tmp=${l_tmp#*|}
            e_name=${l_tmp%%|*}; l_tmp=${l_tmp#*|}
            e_orig=${l_tmp%%|*}; l_tmp=${l_tmp#*|}
            e_trig=${l_tmp%%|*}; e_miss=${l_tmp#*|}
            case "$e_miss" in ''|*[!0-9]*) e_miss=0 ;; esac
            [ -d "/proc/$e_tgid/task/$ctid" ] || continue   # thread died: drop
            case "
$hot_names
" in
                *"
$e_trig
"*)
                    # trigger still hot: hold the boost
                    new_corr_state="${new_corr_state}CORS|$ctid|$e_tgid|$e_start|$e_name|$e_orig|$e_trig|0
"
                    n_cors=$((n_cors + 1)) ;;
                *)
                    # trigger cooling: count down, then restore original nice
                    e_miss=$((e_miss + 1))
                    if [ "$e_miss" -ge "$TP_TCORR_REL_STREAK" ]; then
                        tcorr_set_nice "$e_tgid" "$ctid" "$e_orig" && \
                            log_msg "[TCORR] Demote tid=$ctid ($e_name) nice -> $e_orig (trigger $e_trig cooled) [$pkg]"
                    else
                        new_corr_state="${new_corr_state}CORS|$ctid|$e_tgid|$e_start|$e_name|$e_orig|$e_trig|$e_miss
"
                        n_cors=$((n_cors + 1))
                    fi ;;
            esac
        done
        if [ "$n_cors" -gt 0 ]; then
            printf 'PKG|%s\n%s' "$pkg" "$new_corr_state" > "$TCORR_STATE" 2>/dev/null
        else
            rm -f "$TCORR_STATE" 2>/dev/null
        fi
    else
        rm -f "$trig_f" "$hot_f" "$all_f" 2>/dev/null
    fi

    # drop the per-tid cache vars created in this cycle
    for tid2 in $live_tids $prev_tids; do
        unset "TP_S_$tid2" "TP_N_$tid2"
    done
}

# Affinity dispatcher: per-thread engine when enabled for this mode, else the
# classic whole-app mask.
apply_app_affinity() {
    local pkg=$1
    local mode=$2
    [ -z "$pkg" ] && return
    tpin_load_conf
    AFF_CYCLE=$((AFF_CYCLE + 1))     # drives the periodic kernel re-verify
    if [ "$TP_ENABLED" = "true" ]; then
        case " $TP_PIN_MODES " in
            *" $mode "*)
                apply_app_affinity_smart "$pkg" "$mode"
                return
                ;;
            *)
                # Pinning disabled in this mode: drop any stale pins first.
                release_all_pins "ff" "mode $mode not in pin_modes"
                tcorr_release_all "mode $mode not in pin_modes"
                ;;
        esac
    fi
    apply_app_affinity_legacy "$pkg" "$mode"
}

# --- CLI helpers --------------------------------------------------------------

# Live per-thread view of an app (default: foreground), top 30 by CPU%.
show_thread_top() {
    local pkg=$1
    [ -z "$pkg" ] && pkg=$(get_foreground_app)
    if [ -z "$pkg" ]; then
        echo "No foreground app detected."
        return
    fi
    local now=$(date +%s)
    local tag f2 f3 f4 f5 f6 f7 f8 f9 f10 f11
    if [ -f "$TPIN_STATE" ]; then
        while IFS='|' read -r tag f2 f3 f4 f5 f6 f7 f8 f9 f10 f11; do
            case "$tag" in
                TID) eval "TP_S_$f2=\"$f3|$f4|$f5|$f6|$f7|$f8|$f9|$f10|$f11\"" ;;
            esac
        done < "$TPIN_STATE"
    fi
    echo "=== Threads of $pkg (top 30 by CPU%) ==="
    echo "TID    | CPU% | Mask | Name"
    echo "-------|------|------|-----"
    local pid tp tid statline rest u s j_cur st_cur comm cpu mask l sl
    local OLD_IFS=$IFS
    local out=""
    for pid in $(get_app_pids "$pkg"); do
        [ -d "/proc/$pid/task" ] || continue
        for tp in /proc/$pid/task/[0-9]*; do
            [ -d "$tp" ] || continue
            tid=${tp##*/}
            statline=""
            IFS= read -r statline < "$tp/stat" 2>/dev/null
            [ -n "$statline" ] || continue
            rest=${statline##*)}
            set -- $rest
            u=${12:-0}; s=${13:-0}; st_cur=${20:-0}
            case "$u$s" in ''|*[!0-9]*) continue ;; esac
            case "$st_cur" in ''|*[!0-9]*) continue ;; esac
            j_cur=$((u + s))
            comm=""
            IFS= read -r comm < "$tp/comm" 2>/dev/null
            cpu=0
            local sapplied=""
            eval "sl=\$TP_S_$tid"
            if [ -n "$sl" ]; then
                IFS='|'
                set -- $sl
                IFS=$OLD_IFS
                if [ "$1" = "$pid" ] && [ "$2" = "$st_cur" ]; then
                    local el=$((now - $4))
                    local d=$((j_cur - $3))
                    if [ "$el" -gt 0 ] && [ "$d" -ge 0 ]; then
                        cpu=$((d / el))
                        [ "$cpu" -gt 100 ] && cpu=100
                    fi
                    sapplied=$9
                fi
            fi
            mask=$(read_tid_mask_hex "$pid" "$tid")
            [ -z "$mask" ] && mask="?"
            # '!' = actual mask differs from what the module applied -> the
            # app (or another tool) is managing affinity behind our back
            if [ -n "$sapplied" ] && [ "$mask" != "?" ] && [ "$mask" != "$sapplied" ]; then
                mask="${mask}!"
            fi
            out="${out}${cpu}|${tid}|${mask}|${comm}
"
        done
    done
    printf '%s' "$out" | sort -t'|' -k1,1 -rn | head -n 30 | \
        awk -F'|' '{printf "%-6s | %-4s | %-4s | %s\n", $2, $1, $3, $4}'
}

# Thread Pin Engine status (pinned threads, elastic budget, learned names).
get_tpin_status() {
    tpin_load_conf
    echo "=== Thread Pin Engine ==="
    echo "Enabled: $TP_ENABLED"
    echo "Active in modes: $TP_PIN_MODES"
    echo "Budget: $TP_BASE_CAP slot(s), elastic up to $TP_MAX_CAP"
    echo "Thresholds: hot>=${TP_HOT}% release<=${TP_REL}% (streaks ${TP_HOT_STREAK}/${TP_REL_STREAK} cycles)"
    echo "Escalation: 3rd>=${TP_ESC_TH}% and top2>=${TP_ESC_PAIR}% for ${TP_ESC_STREAK} cycles, temp<${TP_ESC_TEMP}C"
    echo "Thermal release: ${TP_REL_TEMP}C  Big mask: 0x$TP_BIG_MASK"
    echo "Self-pin (daemon): $TP_SELF_PIN -> 0x$TP_SELF_MASK"
    echo ""
    local tag a b c d e f g h i j k
    local s_pkg="" s_expanded=0 npin=0 lines="" c=""
    if [ -f "$TPIN_STATE" ]; then
        while IFS='|' read -r tag a b c d e f g h i j k; do
            case "$tag" in
                PKG) s_pkg=$a; s_expanded=$c ;;
                TID)
                    if [ "$i" = "$TP_BIG_MASK" ]; then
                        npin=$((npin + 1))
                        c=""
                        IFS= read -r c < "/proc/$b/task/$a/comm" 2>/dev/null
                        lines="${lines}${f}|${a}|${c}
"
                    fi
                    ;;
            esac
        done < "$TPIN_STATE"
        echo "Tracked app: $s_pkg"
        if [ "$s_expanded" = 1 ]; then
            echo "Elastic budget: EXPANDED (3 slots)"
        else
            echo "Elastic budget: normal (2 slots)"
        fi
        echo "Pinned threads: $npin"
        if [ -n "$lines" ]; then
            echo "CPU% | TID    | Name"
            echo "-----|--------|-----"
            printf '%s' "$lines" | sort -t'|' -k1,1 -rn | \
                awk -F'|' '{printf "%-4s | %-6s | %s\n", $1, $2, $3}'
        fi
    else
        echo "No active pinning (state file absent)."
    fi
    local fg=$(get_foreground_app)
    if [ -n "$fg" ] && [ -f "$THREAD_LEARN_DB" ]; then
        echo ""
        echo "=== Learned thread names: $fg ==="
        awk -F'|' -v pkg="$fg" -v ms="$TP_TLEARN_MIN_SAMPLES" -v msh="$TP_TLEARN_MIN_SHARE" '
            $1 == pkg {
                share = ($3 > 0) ? int($5 * 100 / $3) : 0
                flag = ($3 >= ms && share >= msh) ? "PRE-PIN" : "learning"
                printf "%-24s | samples=%-3d avg=%-3d%% hot=%-3d%% [%s]\n", $2, $3, $4, share, flag
            }' "$THREAD_LEARN_DB" 2>/dev/null | head -n 15
    fi
    echo ""
    echo "=== Thread Correlation Prediction ==="
    echo "Enabled: $TP_TCORR (window ${TP_TCORR_WIN}s, >=${TP_TCORR_MIN_SAMPLES} trigger samples, >=${TP_TCORR_MIN_SHARE}% follow share)"
    echo "Boost: nice $TP_TCORR_NICE, instant pin candidate: $TP_TCORR_PIN, demote after ${TP_TCORR_REL_STREAK} cold cycles"
    local ctag ctid ctgid cstart cname corig ctrig cmiss cn=0
    if [ -f "$TCORR_STATE" ]; then
        while IFS='|' read -r ctag ctid ctgid cstart cname corig ctrig cmiss; do
            [ "$ctag" = "CORS" ] || continue
            cn=$((cn + 1))
            echo "  boost: tid=$ctid ($cname) orig_nice=$corig trigger=$ctrig"
        done < "$TCORR_STATE"
    fi
    echo "Active correlation boosts: $cn"
    if [ -n "$fg" ] && [ -f "$TCORR_DB" ]; then
        echo ""
        echo "=== Learned correlations: $fg ==="
        echo "Trigger            -> Follower           | Share | Samples"
        echo "-------------------|----------------------|-------|--------"
        awk -F'|' -v pkg="$fg" -v ms="$TP_TCORR_MIN_SAMPLES" '
            FNR == 1 { f++ }
            f == 1 { if ($1 == pkg && $3 == "*") den[$2] = $4; next }
            f == 2 {
                if ($1 != pkg || $3 == "*") next
                d = den[$2]; if (d < ms || d <= 0) next
                printf "%d|%s|%s|%d\n", int($4 * 100 / d), $2, $3, d
            }' "$TCORR_DB" "$TCORR_DB" 2>/dev/null | sort -t'|' -k1,1 -rn | head -n 10 | \
            awk -F'|' '{printf "%-18s -> %-18s | %4s%% | %6s\n", $2, $3, $1, $4}'
    fi
    echo ""
    echo "=== Self-Management Detection ==="
    echo "Enabled: $TP_SELFM (streak $TP_SELFM_STREAK, intervene >=${TP_SELFM_INT_CPU}% for $TP_SELFM_INT_STREAK cycles, observe max $TP_SELFM_OBS_MAX)"
    if [ -f "$SELFM_STATE" ]; then
        local sp se sg sb si so sx
        IFS='|' read -r sp se sg sb si so sx < "$SELFM_STATE" 2>/dev/null
        local smode="manage"
        [ "$se" = "1" ] && smode="MONITOR (excellent, hands-off)"
        echo "Session: $sp -> $smode"
        echo "  good_streak=$sg intervene_streak=$si observed_cycles=$so external_overrides=$sx"
    else
        echo "Session: none yet."
    fi
    if [ -s "$SELFM_DB" ]; then
        echo "Verdicts (pkg | verdict | age):"
        local now_v=$(date +%s) vpkg vv vts
        while IFS='|' read -r vpkg vv vts; do
            case "$vts" in ''|*[!0-9]*) vts=0 ;; esac
            echo "  $vpkg | $vv | $(( (now_v - vts) / 86400 ))d ago"
        done < "$SELFM_DB" 2>/dev/null | head -n 15
    fi
}

# Release all pins and clear the engine state.
reset_tpin() {
    tpin_load_conf
    release_all_pins "ff" "manual reset"
    tcorr_release_all "manual reset"
    rm -f "$TPIN_STATE" "$TCORR_HIST" "$SELFM_STATE" 2>/dev/null
    echo "[+] All thread pins released (original masks restored), correlation boosts restored."
}

# Wipe the self-management verdicts (excellent/bad) and session counters.
reset_selfmanage() {
    rm -f "$SELFM_STATE" 2>/dev/null
    > "$SELFM_DB" 2>/dev/null
    echo "[+] Self-management verdicts reset; apps will be re-observed."
}

# Usage: run_learning_cycle [foreground_app]  (pass the app to avoid a
# duplicate dumpsys call per cycle)
run_learning_cycle() {
    local fg_app=$1
    [ -z "$fg_app" ] && fg_app=$(get_foreground_app)
    [ -z "$fg_app" ] && return
    local cpu_load=$(get_app_cpu_load "$fg_app")
    local mem_mb=$(get_app_memory "$fg_app")
    local threads=$(get_app_threads "$fg_app")
    local gpu_load=$(get_gpu_load)
    local temp=$(get_temperature)
    local battery=$(get_battery_level)
    update_app_learning "$fg_app" "$cpu_load" "$mem_mb" "$threads" "$gpu_load" "$temp" "$battery"
}

get_learning_stats() {
    echo "=== Learning Database Statistics ==="
    echo "Total tracked apps: $(wc -l < "$LEARNING_DB" 2>/dev/null || echo 0)"
    echo ""
    echo "App | Samples | Big% | Little% | GPU% | AvgCPU | AvgMem | AvgThreads"
    echo "----|---------|------|---------|------|--------|--------|----------"
    while IFS='|' read -r pkg count big little gpu cpu mem threads update; do
        printf "%-20s | %7s | %4s | %7s | %4s | %6s | %6s | %10s\n" \
            "$pkg" "$count" "$big" "$little" "$gpu" "$cpu" "$mem" "$threads"
    done < "$LEARNING_DB" 2>/dev/null
}

get_prediction_stats() {
    echo "=== Prediction Database Statistics ==="
    local total_chains=$(wc -l < "$PREDICTION_DB" 2>/dev/null || echo 0)
    echo "Total transition chains: $total_chains"
    echo ""
    echo "From App             -> To App               | Count | Avg Interval (s)"
    echo "---------------------|----------------------|-------|-----------------"
    while IFS='|' read -r prev next count last_ts avg_interval; do
        printf "%-20s -> %-20s | %5s | %17s\n" "$prev" "$next" "$count" "$avg_interval"
    done < "$PREDICTION_DB" 2>/dev/null
    echo ""
    echo "=== Prediction State ==="
    local pred_count=$(read_cfg "$PREDICTION_STATE" "predictions_today" "0")
    local fp_count=$(read_cfg "$PREDICTION_STATE" "false_positives_today" "0")
    local last_pred=$(read_cfg "$PREDICTION_STATE" "last_predicted_app" "N/A")
    echo "Predictions today: $pred_count"
    echo "False positives today: $fp_count"
    echo "Last predicted app: $last_pred"
    if [ "$pred_count" -gt 0 ] 2>/dev/null; then
        local rate=$((fp_count * 100 / pred_count))
        echo "False positive rate: ${rate}%"
    fi
    local lock_until=$(read_cfg "$PREDICTION_STATE" "fp_lockout_until" "0")
    case "$lock_until" in ''|*[!0-9]*) lock_until=0 ;; esac
    local now_ts=$(date +%s)
    if [ "$now_ts" -lt "$lock_until" ] 2>/dev/null; then
        echo "FP lockout: ACTIVE ($((lock_until - now_ts))s remaining, counters already reset)"
    else
        echo "FP lockout: none (breaker arms at $(read_cfg "$PREDICTION_CONF" "fp_min_predictions" "8")+ predictions)"
    fi
    echo ""
    echo "=== Time-of-Day Context (bucket = $(read_cfg "$PREDICTION_CONF" "time_bucket_hours" "2")h, current: $(prediction_time_bucket)) ==="
    local time_lines=$(wc -l < "$PREDICTION_TIME_DB" 2>/dev/null || echo 0)
    echo "Time-weighted transitions: $time_lines"
    echo "From App             -> To App               | Bucket | Count"
    echo "---------------------|----------------------|--------|------"
    sort -t'|' -k4,4 -rn "$PREDICTION_TIME_DB" 2>/dev/null | head -n 15 | \
        awk -F'|' '{printf "%-20s -> %-20s | %6s | %5s\n", $1, $2, $3, $4}'
    echo ""
    echo "=== Second-Order Context (prev2 -> prev1 -> next) ==="
    local so_lines=$(wc -l < "$PREDICTION2_DB" 2>/dev/null || echo 0)
    echo "Second-order chains: $so_lines"
    sort -t'|' -k4,4 -rn "$PREDICTION2_DB" 2>/dev/null | head -n 15 | \
        awk -F'|' '{printf "%-18s -> %-18s -> %-18s | %5s\n", $1, $2, $3, $4}'
}

reset_learning() {
    ensure_learning_db_writable
    > "$LEARNING_DB" 2>/dev/null
    echo "[+] Learning database reset."
}

reset_prediction() {
    ensure_prediction_db_writable
    ensure_prediction_state_writable
    > "$PREDICTION_DB"
    > "$PREDICTION2_DB" 2>/dev/null
    > "$PREDICTION_TIME_DB" 2>/dev/null
    > "$PREDICTION_STATE"
    rm -f "$PREDICTION_ACTIVE"
    echo "[+] Prediction database reset (first/second-order chains, time context, state)."
}
