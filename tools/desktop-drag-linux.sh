#!/usr/bin/env bash
# Start/stop one *owned* Viewflow desktop-drag source session.  Nothing in
# this file runs on login or changes a persistent Hyprland configuration.
set -euo pipefail

die() { printf 'desktop-drag-linux: %s\n' "$*" >&2; exit 1; }
note() { printf 'desktop-drag-linux: %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Usage:
  desktop-drag-linux.sh start --config SOURCE.json --monitor OUTPUT [--window 0xADDRESS] [options]
  desktop-drag-linux.sh stop [--state-dir DIR]

Options for start:
  --peer PATH             vf-media-peer executable (default: build/desktop/vf-media-peer)
  --capture-plugin PATH   capture plugin (default: build/desktop/capture/viewflow-capture.so)
  --capture-plugin-name N Hyprland plugin name (default: viewflow-capture)
  --input-plugin PATH     input plugin (default: build/desktop/input/viewflow-hyprland.so)
  --input-plugin-name N   Hyprland plugin name (default: viewflow-hyprland)
  --state-dir DIR         private, per-session state directory
  --special-workspace N   dedicated special workspace (default: viewflow)
  --empty-desktop        start immediately with automatic window enrollment
  --crossing-timeout SEC  wait for one window in the Viewflow output (default: 0 = wait)

The source process does not start until a selected window is one-shot probed.
The capture plugin is loaded first because the probe needs it; the resulting
local address, PID, stable ID and capture dimensions seed an owned runtime
copy of the source JSON. Stop removes only the headless output, daemon, and
plugin paths recorded by this script.
EOF
}

HYPRCTL=${HYPRCTL:-hyprctl}
JQ=${JQ:-jq}
VF_MEDIA_PEER=${VF_MEDIA_PEER:-build/desktop/vf-media-peer}
CAPTURE_PLUGIN=${CAPTURE_PLUGIN:-build/desktop/capture/viewflow-capture.so}
INPUT_PLUGIN=${INPUT_PLUGIN:-build/desktop/input/viewflow-hyprland.so}
CAPTURE_PLUGIN_NAME=${CAPTURE_PLUGIN_NAME:-viewflow-capture}
INPUT_PLUGIN_NAME=${INPUT_PLUGIN_NAME:-viewflow-hyprland}
SPECIAL_WORKSPACE=${SPECIAL_WORKSPACE:-viewflow}
UNDERLAY_WORKSPACE=${UNDERLAY_WORKSPACE:-viewflow-underlay}

runtime=${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}
state_dir="$runtime/viewflow/desktop-drag"

require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
require_regular_file() { [[ -f $1 ]] || die "required file does not exist: $1"; }

canonical_file() {
    local path=$1
    [[ $path = /* ]] || path="$PWD/$path"
    [[ -f $path ]] || die "required file does not exist: $path"
    cd -- "$(dirname -- "$path")" && printf '%s/%s\n' "$PWD" "$(basename -- "$path")"
}

state_file() { printf '%s/%s\n' "$state_dir" "$1"; }

process_start_token() {
    local pid=$1
    [[ -r /proc/$pid/stat ]] || return 1
    # Field 22 is the kernel start time.  The source executable name cannot
    # contain whitespace, so this is a stable PID-reuse guard for this Linux-
    # only launcher.
    awk '{print $22}' "/proc/$pid/stat"
}

safe_name() {
    [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || die "unexpected virtual output name: $1"
}

activate_special_workspace() {
    local output=$1 workspace=$2 underlay=$3 expression ready=0
    expression="local monitor = hl.get_monitor($(lua_string "$output")); if not monitor then error($(lua_string "Viewflow output is unavailable: $output")) end; monitor:set_workspace($(lua_string "name:$underlay")); monitor:set_special_workspace($(lua_string "$workspace"))"
    "$HYPRCTL" eval "$expression"
    for _ in {1..20}; do
        if "$HYPRCTL" -j monitors | "$JQ" -e --arg output "$output" \
            --arg underlay "$underlay" --arg workspace "special:$workspace" '
            any(.[]; .name == $output and .activeWorkspace.name == $underlay and
                .specialWorkspace.name == $workspace)' >/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done
    [[ $ready == 1 ]] || die "owned output did not activate special workspace special:$workspace"
}

lua_string() {
    # Names are checked above; this is still a serializer rather than manual
    # interpolation into an executable Lua string.
    printf '%s' "$1" | "$JQ" -Rs .
}

plugin_loaded() {
    local path=$1 name=$2
    "$HYPRCTL" -j plugin list 2>/dev/null | "$JQ" -e --arg path "$path" --arg name "$name" \
        'if type == "array" then any(.[]; (.filename // .path // "") == $path or (.name // "") == $name) else false end' \
        >/dev/null
}

record_plugin_if_loaded_here() {
    local path=$1 name=$2
    if plugin_loaded "$path" "$name"; then
        note "plugin is already loaded; leaving ownership with the existing session: $name ($path)"
        return
    fi
    "$HYPRCTL" plugin load "$path"
    plugin_loaded "$path" "$name" || die "Hyprland did not report the plugin as loaded: $name ($path)"
    printf '%s\n' "$path" >>"$(state_file plugins)"
}

cleanup_start_failure() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -d $state_dir ]]; then
        "$0" stop --state-dir "$state_dir" >/dev/null 2>&1 || true
    fi
    exit "$rc"
}

stop() {
    [[ -d $state_dir ]] || { note "no owned desktop-drag session at $state_dir"; return; }
    [[ -O $state_dir ]] || die "refusing state directory not owned by this user: $state_dir"
    chmod 700 "$state_dir"

    if [[ -f $(state_file daemon.pid) ]]; then
        local pid expected_start actual_start
        pid=$(<"$(state_file daemon.pid)")
        if [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
            expected_start=$(<"$(state_file daemon.start)")
            actual_start=$(process_start_token "$pid") || die "cannot validate recorded source PID $pid; state retained"
            [[ $expected_start == "$actual_start" ]] || die "recorded source PID $pid was reused; refusing to signal it"
            kill -TERM "$pid"
            # A source process owns capture cleanup.  Do not KILL it or touch
            # an unrecorded process if it needs longer than this diagnostic wait.
            for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
            kill -0 "$pid" 2>/dev/null && die "owned source PID $pid did not stop; state retained"
        fi
    fi

    if [[ -f $(state_file output) ]]; then
        local output
        output=$(<"$(state_file output)")
        safe_name "$output"
        "$HYPRCTL" output remove "$output"
    fi

    if [[ -f $(state_file plugins) ]]; then
        local plugin
        while IFS= read -r plugin; do
            [[ -n $plugin ]] || continue
            # The list contains only paths this wrapper loaded.  In particular,
            # it never contains an independently loaded Hyprcapture plugin.
            "$HYPRCTL" plugin unload "$plugin"
        done <"$(state_file plugins)"
    fi
    rm -f -- "$(state_file native-control/desktop-window.json)"
    rmdir -- "$(state_file native-control)" 2>/dev/null || true
    local archive parent base
    parent=$(dirname -- "$state_dir")
    base=$(basename -- "$state_dir")
    archive="$parent/${base}.stopped.$(date -u +%Y%m%dT%H%M%SZ).$$"
    [[ ! -e $archive ]] || die "refusing to overwrite existing session archive: $archive"
    mv -- "$state_dir" "$archive"
    chmod 700 "$archive"
    note "owned desktop-drag session stopped; retained logs and effective policy at $archive"
}

probe_and_seed_window() {
    local config=$1 window=$2 output
    local compositor_pid
    compositor_pid=$("$JQ" -er '.compositor_pid | select(type == "number" and . > 0) | floor' "$config") \
        || die "source config has no valid compositor_pid"
    output=$("$VF_MEDIA_PEER" probe --compositor-pid "$compositor_pid" --window "$window") \
        || die "window probe failed; source session was not started"
    printf '%s\n' "$output" >"$(state_file probe.json)"
    "$JQ" -e --arg address "$window" '
        (.address == $address) and
        ((.pid | type) == "number" and .pid > 0) and
        ((.stable_id | type) == "string" and length > 0)
    ' "$(state_file probe.json)" >/dev/null \
        || die "probe output did not contain a valid local window identity"

    local pid stable_id width height geometry_epoch window_id control_dir
    pid=$("$JQ" -r .pid "$(state_file probe.json)")
    stable_id=$("$JQ" -r .stable_id "$(state_file probe.json)")
    width=$("$JQ" -er '.width | select(type == "number" and . >= 1 and . <= 32768) | floor' "$(state_file probe.json)")
    height=$("$JQ" -er '.height | select(type == "number" and . >= 1 and . <= 32768) | floor' "$(state_file probe.json)")
    geometry_epoch=$("$JQ" -er '.geometry_epoch | select(type == "number" and . >= 1) | floor' "$(state_file probe.json)")
    local atlas_width atlas_height
    atlas_width=$("$JQ" -er '(.media.max_width // .media.width) | select(type == "number" and . >= 1) | floor' "$config")
    atlas_height=$("$JQ" -er '(.media.max_height // .media.height) | select(type == "number" and . >= 1) | floor' "$config")
    (( width <= atlas_width && height <= atlas_height )) || \
        die "probed full decorated window ${width}x${height} exceeds configured atlas ${atlas_width}x${atlas_height}; regenerate with --atlas-width/--atlas-height"
    require_command sha256sum
    window_id=$(printf 'viewflow-desktop-window:%s' "$stable_id" | sha256sum | cut -c1-32)
    [[ $window_id != $("$JQ" -r '.media.stream_id' "$config") ]] || \
        window_id=$(printf 'viewflow-desktop-window:1:%s' "$stable_id" | sha256sum | cut -c1-32)
    control_dir="$(state_file native-control)"
    install -d -m 700 "$control_dir"
    install -m 600 /dev/null "$control_dir/desktop-window.json"
    "$JQ" --arg address "$window" --argjson pid "$pid" --arg stable_id "$stable_id" \
        --arg window_id "$window_id" --argjson width "$width" --argjson height "$height" \
        --argjson geometry_epoch "$geometry_epoch" --arg control_dir "$control_dir" '
        .desktop.native_control_dir = $control_dir |
        .desktop.candidates = [{address:$address, pid:$pid, stable_id:$stable_id}] |
        .windows = [{window_id:$window_id, address:$address, width:$width, height:$height, geometry_epoch:$geometry_epoch}]
    ' "$config" >"$(state_file config.next)"
    mv -- "$(state_file config.next)" "$config"
}

wait_for_crossing() {
    local x=$1 y=$2 width=$3 height=$4 timeout_seconds=$5 started=$SECONDS clients found workspaces
    note "waiting for exactly one mapped window to cross into the owned Viewflow output"
    while :; do
        workspaces=$("$HYPRCTL" -j monitors | "$JQ" -c '[.[] | .activeWorkspace.id, .specialWorkspace.id | select(. != null and . != 0)]')
        clients=$("$HYPRCTL" -j clients)
        found=$(printf '%s' "$clients" | "$JQ" -cer --argjson x "$x" --argjson y "$y" --argjson w "$width" --argjson h "$height" --argjson workspaces "$workspaces" '
            [ .[] | select((.mapped // false) and (.floating // false) and ((.hidden // false) | not))
              | select(.workspace.id as $id | $workspaces | index($id))
              | select((.at|type) == "array" and (.size|type) == "array")
              | select(.at[0] < ($x + $w) and $x < (.at[0] + .size[0]) and .at[1] < ($y + $h) and $y < (.at[1] + .size[1]))
              | .address ] | if length == 1 then .[0] else empty end') || true
        if [[ -n $found ]]; then
            printf '%s\n' "$found"
            return
        fi
        (( timeout_seconds == 0 || SECONDS - started < timeout_seconds )) || die "no unique window crossed into the owned output before timeout"
        sleep 0.1
    done
}

start() {
    local config= monitor= window= crossing_timeout=0 empty_desktop=0
    local special_workspace=$SPECIAL_WORKSPACE underlay_workspace=$UNDERLAY_WORKSPACE
    while (($#)); do
        case $1 in
            --config) config=${2:?missing value for --config}; shift 2 ;;
            --monitor) monitor=${2:?missing value for --monitor}; shift 2 ;;
            --empty-desktop) empty_desktop=1; shift ;;
            --window) window=${2:?missing value for --window}; shift 2 ;;
            --peer) VF_MEDIA_PEER=${2:?missing value for --peer}; shift 2 ;;
            --capture-plugin) CAPTURE_PLUGIN=${2:?missing value for --capture-plugin}; shift 2 ;;
            --capture-plugin-name) CAPTURE_PLUGIN_NAME=${2:?missing value for --capture-plugin-name}; shift 2 ;;
            --input-plugin) INPUT_PLUGIN=${2:?missing value for --input-plugin}; shift 2 ;;
            --input-plugin-name) INPUT_PLUGIN_NAME=${2:?missing value for --input-plugin-name}; shift 2 ;;
            --state-dir) state_dir=${2:?missing value for --state-dir}; shift 2 ;;
            --special-workspace) special_workspace=${2:?missing value for --special-workspace}; shift 2 ;;
            --crossing-timeout) crossing_timeout=${2:?missing value for --crossing-timeout}; shift 2 ;;
            --help|-h) usage; return ;;
            *) die "unknown start option: $1" ;;
        esac
    done
    [[ -n $config && -n $monitor ]] || die "start requires --config and --monitor"
    safe_name "$special_workspace"
    safe_name "$underlay_workspace"
    [[ -z $window || $window =~ ^0x[0-9A-Fa-f]{1,16}$ && $window != 0x0 ]] || die "--window must be a nonzero Hyprland 0x address"
    [[ $crossing_timeout =~ ^[0-9]+$ ]] || die "--crossing-timeout must be a non-negative number of seconds"
    [[ $state_dir = /* ]] || die "--state-dir must be absolute"
    require_command "$HYPRCTL"; require_command "$JQ"
    config=$(canonical_file "$config")
    VF_MEDIA_PEER=$(canonical_file "$VF_MEDIA_PEER")
    CAPTURE_PLUGIN=$(canonical_file "$CAPTURE_PLUGIN")
    INPUT_PLUGIN=$(canonical_file "$INPUT_PLUGIN")
    [[ $CAPTURE_PLUGIN_NAME =~ ^[A-Za-z0-9._-]+$ && $INPUT_PLUGIN_NAME =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "plugin names must contain only letters, digits, dot, underscore, or dash"
    [[ $CAPTURE_PLUGIN != *hyprcapture* && $INPUT_PLUGIN != *hyprcapture* ]] \
        || die "this wrapper will not take ownership of a Hyprcapture plugin"

    mkdir -p -m 700 "$(dirname -- "$state_dir")"
    [[ ! -e $state_dir ]] || die "an owned desktop-drag session state already exists: $state_dir"
    install -d -m 700 "$state_dir"
    trap cleanup_start_failure EXIT INT TERM

    local native_socket="$runtime/viewflow/hyprland.sock"
    local command_socket="$runtime/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?HYPRLAND_INSTANCE_SIGNATURE is required}/.socket.sock"
    # VIEWFLOW_HYPRLAND_SOCKET is sampled by the plugin when Hyprland starts.
    # A launcher cannot safely change it later, so this wrapper deliberately
    # uses the documented default and rejects a pre-existing daemon/socket.
    [[ -z ${VIEWFLOW_HYPRLAND_SOCKET:-} || ${VIEWFLOW_HYPRLAND_SOCKET} == "$native_socket" ]] \
        || die "custom VIEWFLOW_HYPRLAND_SOCKET must be set before Hyprland starts; this launcher uses $native_socket"
    [[ ! -e $native_socket ]] || die "native Hyprland socket already exists: $native_socket"

    "$JQ" -e --arg native_socket "$native_socket" --arg command_socket "$command_socket" '
        (.desktop != null) and
        (.desktop.hyprland_socket == $command_socket) and
        (.desktop.native_control_dir | type == "string" and startswith("/")) and
        (.pointer.native_socket == $native_socket) and
        (.desktop.local_display.width > 0) and (.desktop.local_display.height > 0) and
        (.desktop.remote_display.width > 0) and (.desktop.remote_display.height > 0)
    ' "$config" >/dev/null || die "config does not use the current Hyprland command socket and Viewflow native input socket"
    local current_compositor_pid
    current_compositor_pid=$("$HYPRCTL" -j instances | "$JQ" -er --arg signature "$HYPRLAND_INSTANCE_SIGNATURE" \
        '[.[] | select(.instance == $signature)][0].pid | select(type == "number" and . > 0) | floor') \
        || die "could not read the active Hyprland PID for this session"
    "$JQ" -e --argjson pid "$current_compositor_pid" '.compositor_pid == $pid' "$config" >/dev/null \
        || die "source config compositor_pid is stale for the current Hyprland session"

    local monitors selected local_x local_y local_w local_h transform scale remote_x remote_y remote_w remote_h remote_scale remote_logical_w remote_logical_h
    monitors=$("$HYPRCTL" -j monitors all)
    selected=$(printf '%s' "$monitors" | "$JQ" -ce --arg name "$monitor" '.[] | select(.name == $name)') \
        || die "selected monitor is absent: $monitor"
    local_x=$(printf '%s' "$selected" | "$JQ" -er '.x | floor')
    local_y=$(printf '%s' "$selected" | "$JQ" -er '.y | floor')
    scale=$(printf '%s' "$selected" | "$JQ" -er '.scale')
    transform=$(printf '%s' "$selected" | "$JQ" -er '.transform // 0')
    local_w=$(printf '%s' "$selected" | "$JQ" -er '.width')
    local_h=$(printf '%s' "$selected" | "$JQ" -er '.height')
    case $transform in 1|3|5|7) local tmp=$local_w; local_w=$local_h; local_h=$tmp ;; esac
    remote_x=$("$JQ" -er '.desktop.remote_display.x' "$config")
    remote_y=$("$JQ" -er '.desktop.remote_display.y' "$config")
    remote_w=$("$JQ" -er '.desktop.remote_display.width' "$config")
    remote_h=$("$JQ" -er '.desktop.remote_display.height' "$config")
    remote_scale=$("$JQ" -er '.desktop.remote_display.scale' "$config")
    remote_logical_w=$("$JQ" -er '.desktop.remote_display | .width / .scale' "$config")
    remote_logical_h=$("$JQ" -er '.desktop.remote_display | .height / .scale' "$config")
    # The selected local display must match its live physical resolution,
    # scale and coordinates. The remote origin is explicit, with no edge map.
    "$JQ" -e --argjson x "$local_x" --argjson y "$local_y" --argjson w "$local_w" --argjson h "$local_h" \
        --argjson scale "$scale" '
        .desktop.local_display == {x:$x,y:$y,width:$w,height:$h,scale:$scale} and
        (.desktop.remote_display as $r |
         ($r.scale >= 0.125 and $r.scale <= 8) and
         ($x + $w / $scale <= $r.x or $r.x + $r.width / $r.scale <= $x or
          $y + $h / $scale <= $r.y or $r.y + $r.height / $r.scale <= $y))
    ' "$config" >/dev/null || die "configured displays overlap or the local monitor configuration is stale"

    cp -- "$config" "$(state_file config)"

    local before after output mode lua
    before=$(printf '%s' "$monitors" | "$JQ" -r '.[].name' | sort)
    "$HYPRCTL" output create headless
    after=$("$HYPRCTL" -j monitors all | "$JQ" -r '.[].name' | sort)
    output=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n '1p')
    [[ -n $output ]] || die "could not determine the new owned headless output"
    safe_name "$output"
    printf '%s\n' "$output" >"$(state_file output)"
    mode="${remote_w}x${remote_h}@60"
    lua="hl.monitor({ output = $(lua_string "$output"), mode = $(lua_string "$mode"), position = $(lua_string "${remote_x}x${remote_y}"), scale = $(lua_string "$remote_scale") })"
    "$HYPRCTL" eval "$lua"
    local layout_ready=0 attempt
    for attempt in {1..20}; do
        if "$HYPRCTL" -j monitors all | "$JQ" -e --arg name "$output" \
            --argjson x "$remote_x" --argjson y "$remote_y" \
            --argjson w "$remote_w" --argjson h "$remote_h" --argjson scale "$remote_scale" '
            any(.[]; .name == $name and .x == $x and .y == $y and
                .width == $w and .height == $h and .scale == $scale and
                (.disabled // false | not))' >/dev/null; then
            layout_ready=1
            break
        fi
        sleep 0.1
    done
    [[ $layout_ready == 1 ]] || die "new headless output did not reach the requested layout and usable dimensions"
    activate_special_workspace "$output" "$special_workspace" "$underlay_workspace"

    # The one-shot probe requires the capture plugin.  It runs after this
    # owned load, but before sender/input startup, and leaves no producer live.
    : >"$(state_file plugins)"
    record_plugin_if_loaded_here "$CAPTURE_PLUGIN" "$CAPTURE_PLUGIN_NAME"
    # Plugin loading schedules a config reload, which can reset runtime output rules.
    sleep 0.3
    "$HYPRCTL" eval "$lua"
    activate_special_workspace "$output" "$special_workspace" "$underlay_workspace"
    if [[ $empty_desktop == 1 ]]; then
        [[ -z $window ]] || die "--empty-desktop cannot be combined with --window"
        install -d -m 700 "$(state_file native-control)"
        "$JQ" --arg control_dir "$(state_file native-control)" '
            .windows = [] | .desktop.candidates = [] | .desktop.auto_enroll = true |
            .desktop.native_control_dir = $control_dir
        ' "$(state_file config)" >"$(state_file config.next)"
        mv -- "$(state_file config.next)" "$(state_file config)"
    else
        if [[ -z $window ]]; then
            window=$(wait_for_crossing "$remote_x" "$remote_y" "$remote_logical_w" "$remote_logical_h" "$crossing_timeout")
        fi
        probe_and_seed_window "$(state_file config)" "$window"
    fi
    "$VF_MEDIA_PEER" validate-send --config "$(state_file config)" \
        || die "seeded source configuration failed offline validation; sender was not started"
    record_plugin_if_loaded_here "$INPUT_PLUGIN" "$INPUT_PLUGIN_NAME"
    sleep 0.3
    "$HYPRCTL" eval "$lua"
    activate_special_workspace "$output" "$special_workspace" "$underlay_workspace"
    sleep 0.2

    # Capture authority comes only from this freshly created, read-back checked
    # output. Never persist/reuse an ID from the user's paired configuration.
    local owned_monitor_id
    owned_monitor_id=$("$HYPRCTL" -j monitors all | "$JQ" -er --arg name "$output" \
        --arg workspace "$special_workspace" \
        --arg underlay "$underlay_workspace" \
        --argjson x "$remote_x" --argjson y "$remote_y" \
        --argjson w "$remote_w" --argjson h "$remote_h" --argjson scale "$remote_scale" '
        [.[] | select(.name == $name and .x == $x and .y == $y and
            .width == $w and .height == $h and .scale == $scale and
            .activeWorkspace.name == $underlay and
            .specialWorkspace.name == "special:" + $workspace and
            (.disabled // false | not))] |
        select(length == 1) | .[0].id | select(type == "number" and . >= 0 and . == floor)') \
        || die "owned output changed before capture authority could be bound"
    "$JQ" --argjson id "$owned_monitor_id" '.pointer.cursor_monitor_id = $id' \
        "$(state_file config)" >"$(state_file config.next)"
    mv -- "$(state_file config.next)" "$(state_file config)"
    "$VF_MEDIA_PEER" validate-send --config "$(state_file config)" \
        || die "owned cursor configuration failed offline validation"

    "$VF_MEDIA_PEER" send --config "$(state_file config)" >"$(state_file source.log)" 2>&1 &
    local daemon_pid=$!
    printf '%s\n' "$daemon_pid" >"$(state_file daemon.pid)"
    process_start_token "$daemon_pid" >"$(state_file daemon.start)" || die "could not record source process identity"
    sleep 0.1
    kill -0 "$daemon_pid" 2>/dev/null || die "source process exited during startup; see $(state_file source.log)"
    trap - EXIT INT TERM
    note "started; move the selected local window into $output at (${remote_x},${remote_y}), ${remote_w}x${remote_h} pixels, scale ${remote_scale}. Stop with: $0 stop --state-dir $state_dir"
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
command=$1; shift
case $command in
    start) start "$@" ;;
    stop)
        while (($#)); do
            case $1 in
                --state-dir) state_dir=${2:?missing value for --state-dir}; shift 2 ;;
                --help|-h) usage; exit 0 ;;
                *) die "unknown stop option: $1" ;;
            esac
        done
        [[ $state_dir = /* ]] || die "--state-dir must be absolute"
        require_command "$HYPRCTL"
        stop
        ;;
    --help|-h|help) usage ;;
    *) die "unknown command: $command" ;;
esac
