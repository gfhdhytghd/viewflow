#!/usr/bin/env bash
# Fresh, local-only identity preparation for one manual desktop-drag trial.
set -euo pipefail

die() { printf 'desktop-drag-pair: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  desktop-drag-pair.sh prepare --dir ABSOLUTE_DIR --monitor OUTPUT --linux-ip IP \\
      --windows-host DNS --windows-ip IP --windows-resolution WIDTHxHEIGHT --windows-scale FACTOR --windows-position XxY \\
      [--atlas-width PX --atlas-height PX] [--occlusion off|opaque|prerender]
  desktop-drag-pair.sh inspect-windows --host SSH_HOST

prepare reads the selected Linux monitor and writes paired source/receiver JSON
plus fresh short-lived TLS identities in a new private directory. It does not
copy anything to Windows. inspect-windows is read-only and checks the exact
staging directory C:\Users\wilf\Viewflow\desktop-test before a separate,
explicit provisioning operation.
EOF
}

prepare() {
    local dir= monitor= linux_ip= windows_host= windows_ip= windows_width= windows_height= windows_scale=
    local remote_position= windows_x=0 windows_y=0 source_port=44130 receiver_port=44129 refresh_hz=60 atlas_width=1024 atlas_height=1024 occlusion=opaque
    local windows_root='C:\Users\wilf\Viewflow\desktop-test'
    while (($#)); do
        case $1 in
            --occlusion) occlusion=${2:?missing value for --occlusion}; case $occlusion in off|opaque|prerender) ;; *) die "occlusion must be off, opaque, or prerender" ;; esac; shift 2 ;;
            --dir) dir=${2:?missing value for --dir}; shift 2 ;;
            --monitor) monitor=${2:?missing value for --monitor}; shift 2 ;;
            --linux-ip) linux_ip=${2:?missing value for --linux-ip}; shift 2 ;;
            --windows-host) windows_host=${2:?missing value for --windows-host}; shift 2 ;;
            --windows-ip) windows_ip=${2:?missing value for --windows-ip}; shift 2 ;;
            --windows-resolution) local resolution=${2:?missing value for --windows-resolution}; [[ $resolution =~ ^([0-9]+)x([0-9]+)$ ]] || die "resolution must be WIDTHxHEIGHT"; windows_width=${BASH_REMATCH[1]}; windows_height=${BASH_REMATCH[2]}; shift 2 ;;
            --windows-position) remote_position=${2:?missing value for --windows-position}; shift 2 ;;
            --windows-width) windows_width=${2:?missing value for --windows-width}; shift 2 ;;
            --windows-height) windows_height=${2:?missing value for --windows-height}; shift 2 ;;
            --windows-scale) windows_scale=${2:?missing value for --windows-scale}; shift 2 ;;
            --native-x) windows_x=${2:?missing value for --native-x}; shift 2 ;;
            --native-y) windows_y=${2:?missing value for --native-y}; shift 2 ;;
            --source-port) source_port=${2:?missing value for --source-port}; shift 2 ;;
            --receiver-port) receiver_port=${2:?missing value for --receiver-port}; shift 2 ;;
            --refresh-hz) refresh_hz=${2:?missing value for --refresh-hz}; shift 2 ;;
            --atlas-width) atlas_width=${2:?missing value for --atlas-width}; shift 2 ;;
            --atlas-height) atlas_height=${2:?missing value for --atlas-height}; shift 2 ;;
            --windows-root) windows_root=${2:?missing value for --windows-root}; shift 2 ;;
            *) die "unknown prepare option: $1" ;;
        esac
    done
    [[ $dir = /* ]] || die "--dir must be absolute"
    [[ -n $monitor && -n $linux_ip && -n $windows_host && -n $windows_ip && -n $windows_width && -n $windows_height && -n $windows_scale && -n $remote_position ]] \
        || die "prepare requires monitor, both peer IPs, Windows host, physical resolution, scale factor and global position"
    [[ $windows_host =~ ^[A-Za-z0-9.-]+$ ]] || die "--windows-host must be DNS-like"
    for number in "$windows_width" "$windows_height" "$source_port" "$receiver_port" "$refresh_hz" "$atlas_width" "$atlas_height"; do
        [[ $number =~ ^[0-9]+$ && $number -gt 0 ]] || die "pixel sizes, ports and refresh rate must be positive integers"
    done
    [[ $remote_position =~ ^(-?[0-9]+)x(-?[0-9]+)$ ]] || die "--windows-position must be XxY in logical coordinates"
    local remote_x=${BASH_REMATCH[1]} remote_y=${BASH_REMATCH[2]}
    [[ $windows_scale =~ ^[0-9]+(\.[0-9]{1,3})?$ ]] || die "--windows-scale must be a factor such as 1, 1.25 or 1.5"
    [[ $windows_x =~ ^-?[0-9]+$ && $windows_y =~ ^-?[0-9]+$ ]] || die "--native-x and --native-y must be integers"
    (( windows_width <= 32768 && windows_height <= 32768 && 
       source_port <= 65535 && receiver_port <= 65535 && refresh_hz <= 1000 &&
       windows_x >= -1000000 && windows_x <= 1000000 && windows_y >= -1000000 && windows_y <= 1000000 )) \
        || die "Windows viewport, scale, ports, refresh rate, or origin is outside the peer policy bounds"
    [[ ! -e $dir ]] || die "refusing to overwrite existing pair directory: $dir"
    command -v openssl >/dev/null || die "openssl is required"
    command -v hyprctl >/dev/null || die "hyprctl is required to read the selected Linux monitor"
    command -v jq >/dev/null || die "jq is required"
    local selected local_x local_y local_width local_height local_scale transform remote_width remote_height compositor_pid
    selected=$(hyprctl -j monitors all | jq -ce --arg name "$monitor" '.[] | select(.name == $name)') \
        || die "selected Linux monitor is absent: $monitor"
    local_x=$(printf '%s' "$selected" | jq -er '.x | floor')
    local_y=$(printf '%s' "$selected" | jq -er '.y | floor')
    local_width=$(printf '%s' "$selected" | jq -er '.width')
    local_height=$(printf '%s' "$selected" | jq -er '.height')
    local_scale=$(printf '%s' "$selected" | jq -er '.scale')
    transform=$(printf '%s' "$selected" | jq -er '.transform // 0')
    case $transform in 1|3|5|7) local tmp=$local_width; local_width=$local_height; local_height=$tmp ;; esac
    jq -en --argjson scale "$windows_scale" --argjson x "$remote_x" --argjson y "$remote_y" '
        $scale >= 0.125 and $scale <= 8 and ($x | fabs) <= 1000000 and ($y | fabs) <= 1000000
    ' >/dev/null || die "display scale or global position is outside policy bounds"
    remote_width=$(jq -n --argjson w "$windows_width" --argjson scale "$windows_scale" '$w / $scale')
    remote_height=$(jq -n --argjson h "$windows_height" --argjson scale "$windows_scale" '$h / $scale')
    jq -en --argjson x "$local_x" --argjson y "$local_y" --argjson w "$local_width" --argjson h "$local_height" \
        --argjson scale "$local_scale" --argjson rx "$remote_x" --argjson ry "$remote_y" \
        --argjson rw "$remote_width" --argjson rh "$remote_height" '
        $x + $w / $scale <= $rx or $rx + $rw <= $x or
        $y + $h / $scale <= $ry or $ry + $rh <= $y
    ' >/dev/null || die "configured displays overlap in global logical coordinates"
    compositor_pid=$(hyprctl -j instances | jq -er --arg signature "${HYPRLAND_INSTANCE_SIGNATURE:?HYPRLAND_INSTANCE_SIGNATURE is required}" \
        '[.[] | select(.instance == $signature)][0].pid | select(type == "number" and . > 0) | floor') \
        || die "could not read the active Hyprland PID"
    local stream_id owner_device source_device max_decoded native_socket command_socket
    stream_id=$(openssl rand -hex 16); owner_device=$(openssl rand -hex 16); source_device=$(openssl rand -hex 16)
    [[ $stream_id != 00000000000000000000000000000000 && $owner_device != "$source_device" ]] || die "random identity generation failed"
    (( atlas_width >= 64 && atlas_width <= 8192 && atlas_height >= 64 && atlas_height <= 4096 )) \
        || die "atlas dimensions must be between 64x64 and 8192x4096 pixels"
    max_decoded=268435456
    native_socket="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}/viewflow/hyprland.sock"
    command_socket="${XDG_RUNTIME_DIR}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?HYPRLAND_INSTANCE_SIGNATURE is required}/.socket.sock"
    umask 077
    install -d -m 700 "$dir"
    trap 'rm -rf -- "$dir"' ERR INT TERM
    openssl genpkey -algorithm ED25519 -out "$dir/pair-ca.key"
    openssl req -x509 -new -key "$dir/pair-ca.key" -out "$dir/pair-ca.pem" -days 7 -subj '/CN=viewflow-desktop-test-ca'
    make_identity() {
        local role=$1 name=$2
        openssl genpkey -algorithm ED25519 -out "$dir/$role.key"
        openssl req -new -key "$dir/$role.key" -out "$dir/$role.csr" -subj "/CN=$name"
        printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$name" >"$dir/$role.ext"
        openssl x509 -req -in "$dir/$role.csr" -CA "$dir/pair-ca.pem" -CAkey "$dir/pair-ca.key" \
            -CAcreateserial -out "$dir/$role.pem" -days 7 -extfile "$dir/$role.ext"
        rm -f -- "$dir/$role.csr" "$dir/$role.ext"
    }
    make_identity source viewflow-linux
    make_identity receiver "$windows_host"
    chmod 600 "$dir"/*.key
    chmod 644 "$dir"/*.pem
    cat >"$dir/send.json" <<EOF
{
  "desktop": {"topology_generation": 1, "local_display": {"x": $local_x, "y": $local_y, "width": $local_width, "height": $local_height, "scale": $local_scale}, "remote_display": {"x": $remote_x, "y": $remote_y, "width": $windows_width, "height": $windows_height, "scale": $windows_scale}, "hyprland_socket": "$command_socket", "native_control_dir": "$dir/runtime-control", "auto_enroll": true, "max_enrolled_windows": 8, "candidates": []},
  "pointer": {"devices": {"owner_device": "$owner_device", "source_device": "$source_device"}, "native_socket": "$native_socket", "wheel": true, "direct_keyboard": true},
  "capture_provider": "viewflow", "disposition_recovery": true, "occlusion": "$occlusion",
  "bind": "0.0.0.0:$source_port", "remote": "$windows_ip:$receiver_port", "server_name": "$windows_host",
  "certificate": "$dir/source.pem", "private_key": "$dir/source.key", "certificate_authority": "$dir/pair-ca.pem", "compositor_pid": $compositor_pid,
  "fps": $refresh_hz, "startup_timeout_ms": 10000, "media_idle_timeout_ms": 3000,
  "media": {"stream_id": "$stream_id", "geometry_epoch": 1, "config_generation": 1, "width": $atlas_width, "height": $atlas_height, "max_width": 8192, "max_height": 4096, "max_tiles": 8, "max_encoded_bytes": 134217728, "max_decoded_bytes": $max_decoded, "refresh_hz": $refresh_hz}, "windows": []
}
EOF
    local receiver_cert receiver_key receiver_ca receiver_presenter
    receiver_cert=$(printf '%s\\receiver.pem' "$windows_root" | jq -Rs .)
    receiver_key=$(printf '%s\\receiver.key' "$windows_root" | jq -Rs .)
    receiver_ca=$(printf '%s\\pair-ca.pem' "$windows_root" | jq -Rs .)
    receiver_presenter=$(printf '%s\\viewflow_windows_composition_preview.exe' "$windows_root" | jq -Rs .)
    cat >"$dir/receive.json" <<EOF
{
  "desktop": {"display": {"x": $remote_x, "y": $remote_y, "width": $windows_width, "height": $windows_height, "scale": $windows_scale}, "native_x": $windows_x, "native_y": $windows_y},
  "pointer": {"owner_device": "$owner_device", "source_device": "$source_device", "wheel": true, "direct_keyboard": true}, "disposition_recovery": true, "input_recovery": true,
  "bind": "0.0.0.0:$receiver_port", "expected_peer_ip": "$linux_ip", "certificate": $receiver_cert, "private_key": $receiver_key, "certificate_authority": $receiver_ca, "native_presenter": $receiver_presenter,
  "stream_id": "$stream_id", "geometry_epoch": 1, "config_generation": 1, "width": $atlas_width, "height": $atlas_height, "max_width": 8192, "max_height": 4096, "max_tiles": 8, "max_encoded_bytes": 134217728, "max_decoded_bytes": $max_decoded, "refresh_hz": $refresh_hz, "startup_timeout_ms": 10000, "media_idle_timeout_ms": 3000, "clock_silence_timeout_ms": 3000
}
EOF
    jq -e . "$dir/send.json" >/dev/null && jq -e . "$dir/receive.json" >/dev/null
    printf 'windows_host=%s\nwindows_ip=%s\nlinux_ip=%s\nmonitor=%s\ncreated_utc=%s\n' "$windows_host" "$windows_ip" "$linux_ip" "$monitor" "$(date -u +%FT%TZ)" >"$dir/pair.env"
    chmod 600 "$dir/pair.env"
    trap - ERR INT TERM
    printf 'fresh pair and generated configs created at %s (directory 0700; private keys 0600)\n' "$dir"
}

inspect_windows() {
    local host=
    while (($#)); do
        case $1 in --host) host=${2:?missing value for --host}; shift 2 ;; *) die "unknown inspect-windows option: $1" ;; esac
    done
    [[ -n $host ]] || die "inspect-windows requires --host"
    command -v ssh >/dev/null || die "ssh is required"
    # No shell-derived remote target: the command contains exactly the approved
    # staging directory and only asks PowerShell to report its existence.
    ssh -- "$host" 'powershell -NoProfile -NonInteractive -Command "if (Test-Path -LiteralPath '\''C:\Users\wilf\Viewflow\desktop-test'\'' -PathType Container) { exit 0 } else { exit 3 }"'
    printf 'Windows staging directory exists; this command made no remote changes.\n'
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
command=$1; shift
case $command in
    prepare) prepare "$@" ;;
    inspect-windows) inspect_windows "$@" ;;
    --help|-h|help) usage ;;
    *) die "unknown command: $command" ;;
esac
