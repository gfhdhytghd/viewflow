#!/usr/bin/env bash

set -euo pipefail

run_quick() {
    timeout 2s "$@" 2>/dev/null || true
}

# WiFi radio state
wifi_enabled=false
if command -v nmcli >/dev/null 2>&1; then
    state="$(run_quick nmcli radio wifi)"
    [[ "$state" == "enabled" ]] && wifi_enabled=true
fi
printf 'wifi_enabled=%s\n' "$wifi_enabled"

# Brightness is read by quickAdjustBrightnessProbe on panel open and after
# user adjustments. Periodic DDC/CI queries stall the NVIDIA import path.
# Omit brightness here so unrelated status polling keeps the current UI value.

# DND (Do Not Disturb) state
dnd=false
if command -v swaync-client >/dev/null 2>&1; then
    dnd_state="$(run_quick swaync-client -D)"
    [[ "$dnd_state" == "true" ]] && dnd=true
fi
printf 'dnd=%s\n' "$dnd"

# Screen recording detection
recording=false
if pgrep -x 'wf-recorder' >/dev/null 2>&1 || \
   pgrep -x 'wl-screenrec' >/dev/null 2>&1 || \
   pgrep -x 'gpu-screen-recorder' >/dev/null 2>&1; then
    recording=true
fi
printf 'recording=%s\n' "$recording"

# Power profile
power_profile="balanced"
if command -v powerprofilesctl >/dev/null 2>&1; then
    power_profile="$(run_quick powerprofilesctl get)"
    [[ -z "$power_profile" ]] && power_profile="balanced"
fi
printf 'power_profile=%s\n' "$power_profile"

# Prevent sleep state
prevent_sleep=false
if [[ -x "${HOME}/.config/HyprV/quickshell/scripts/prevent-sleep.sh" ]]; then
    inhibit_status="$("${HOME}/.config/HyprV/quickshell/scripts/prevent-sleep.sh" status 2>/dev/null || true)"
    if [[ "$inhibit_status" == *"enabled=true"* ]]; then
        prevent_sleep=true
    fi
fi
printf 'prevent_sleep=%s\n' "$prevent_sleep"

# Demo mode state
demo_mode=false
if [[ -x "${HOME}/.config/HyprV/quickshell/scripts/demo-mode.sh" ]]; then
    demo_status="$("${HOME}/.config/HyprV/quickshell/scripts/demo-mode.sh" status 2>/dev/null || true)"
    if [[ "$demo_status" == *"enabled=true"* ]]; then
        demo_mode=true
    fi
fi
printf 'demo_mode=%s\n' "$demo_mode"

# Chassis fan controller state. The helper resolves the dynamic hwmon path by
# chip name and only reports the two channels exposed by the control panel.
fan_helper="/usr/local/libexec/hyprv-fanctl"
if [[ -x "$fan_helper" ]]; then
    "$fan_helper" status 2>/dev/null || printf 'fan_available=false\n'
else
    printf 'fan_available=false\n'
fi
