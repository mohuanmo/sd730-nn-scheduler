#!/system/bin/sh
# =====================================================================
# SD730 Smart Scheduler - Scene (com.omarea.vtools) entry point
#
# This file is installed to /data/powercfg.sh at boot (post-fs-data.sh).
# Do NOT edit /data/powercfg.sh directly - it is regenerated every boot.
#
# Scene calls it as root:
#   sh /data/powercfg.sh <powersave|balance|performance|fast>
# =====================================================================

MODDIR="/data/adb/modules/sd730-scheduler"
SCENE_MODE_FILE="$MODDIR/config/scene_mode"
STATE_FILE="/sdcard/Android/sd730-scheduler/cur_powermode.txt"

# Map Scene's mode names to this module's internal modes.
# Scene uses the uperf-style names: powersave / balance / performance / fast
case "$1" in
    powersave)   MODE="powersave"   ;;
    balance)     MODE="balanced"    ;;
    performance) MODE="performance" ;;
    fast)        MODE="ultra"       ;;
    auto|"")     MODE="auto"        ;;
    *)           MODE="auto"        ;;
esac

# Hand the request to the daemon. service.sh polls this file every ~3s,
# validates the value, and applies it (with thermal/battery guards intact).
# The PREVIOUS scene_mode is captured first so the vote gate can tell a real
# mode change from a re-assert of the mode already in effect.
OLD_MODE=""
[ -f "$SCENE_MODE_FILE" ] && OLD_MODE=$(cat "$SCENE_MODE_FILE" 2>/dev/null | tr -d '[:space:]')
[ -d "$MODDIR" ] && echo "$MODE" > "$SCENE_MODE_FILE" 2>/dev/null

# Learn GENUINE manual Scene toggles as a user preference for the foreground
# app. Scene's own automation reaches this script too - per-app bindings
# (fires on every app enter/exit), screen-off and energy-adaptation triggers,
# boot restore and re-asserts - so record_scene_switch() gates the vote:
# only a screen-on call made while the foreground app has been stable, that
# actually changes the mode, counts (plus a same-mode cooldown backstop).
# The module's own auto-apply never reaches this path, so no feedback loop.
case "$MODE" in
    powersave|balanced|performance|ultra)
        if [ -f "$MODDIR/common/functions.sh" ]; then
            . "$MODDIR/common/functions.sh"
            _fg=$(get_foreground_app)
            [ -n "$_fg" ] && record_scene_switch "$_fg" "$MODE" "$OLD_MODE"
        fi
        ;;
esac

# State file shown in Scene's UI (kept in Scene's own mode naming).
# /sdcard may not be mounted yet when this runs very early - ignore errors.
{ mkdir -p "${STATE_FILE%/*}" && echo "${1:-auto}" > "$STATE_FILE"; } 2>/dev/null

exit 0
