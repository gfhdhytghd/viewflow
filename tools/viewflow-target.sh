#!/usr/bin/env bash
set -euo pipefail
readonly config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/viewflow"
readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hyprv"
readonly runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/viewflow"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly hdmi_helper="${VIEWFLOW_HDMI_HELPER:-${XDG_CONFIG_HOME:-$HOME/.config}/HyprV/quickshell/scripts/hdmi-switch-ir.py}"
unit_for() {
  case "$1" in
    windows) echo viewflow-windows-input.service ;;
    macos) echo viewflow-macos-input.service ;;
    *) return 2 ;;
  esac
}
current_target() {
  if systemctl --user is-active --quiet viewflow-macos-input.service; then echo macos
  elif systemctl --user is-active --quiet viewflow-windows-input.service || systemctl --user is-active --quiet viewflow-desktop.service; then echo windows
  elif [[ -r "$state_dir/viewflow-target" ]]; then cat "$state_dir/viewflow-target"
  else echo windows
  fi
}
target_config() {
  case "$1" in
    windows) echo "$config_dir/windows-input-source.json" ;;
    macos) echo "$config_dir/macos-input-source.json" ;;
  esac
}
prepare_target() {
  local args=(--config "$(target_config "$1")")
  if [[ "$1" == windows ]]; then args+=(--start-windows); fi
  python3 "$script_dir/desktop_peer_discovery.py" "${args[@]}"
}
wait_ready() {
  local target=$1 expected_remote=$2
  python3 - "$(target_config "$target")" "$runtime" "$expected_remote" <<'CHECK'
import pathlib,sys,time,json
source,root,expected_remote=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
template=json.loads(source.read_text())
for _ in range(100):
    try:
        pid=int((root/'desktop-drag/daemon.pid').read_text())
        executable=pathlib.Path(f'/proc/{pid}/exe').resolve(strict=True)
        valid=executable.name=='vf-cursor-peer' and (root/'hyprland.sock').exists()
        valid=valid and int((root/'cursor-ready').read_text())==pid
        config=json.loads((root/'desktop-drag/config').read_text())
        valid=valid and config['remote']==expected_remote
        valid=valid and config['pointer']['devices']==template['pointer']['devices']
        valid=valid and config['server_name']==template['server_name']
        if valid: sys.exit(0)
    except (OSError,ValueError,KeyError): pass
    time.sleep(.2)
raise SystemExit('Viewflow 连接未就绪；请检查服务日志。')
CHECK
}
case "${1:-}" in
  status)
    if [[ -r "$state_dir/hdmi-target" ]]; then cat "$state_dir/hdmi-target"
    else current_target
    fi
    ;;
  set)
    requested=${2:-}
    requested_unit=$(unit_for "$requested") || { echo '目标必须是 windows 或 macos' >&2; exit 2; }
    mkdir -p "$config_dir" "$state_dir"
    exec 9>"$config_dir/target-switch.lock"
    flock 9
    # HDMI must remain usable even when a Viewflow peer cannot connect.
    case "$requested" in windows) button=input1 ;; macos) button=input2 ;; esac
    if ! "$hdmi_helper" send "$button" >/dev/null; then
      printf 'HDMI 切换到 %s 失败。\n' "$requested" >&2
      exit 1
    fi
    temporary=$(mktemp "$state_dir/.hdmi-target.XXXXXX")
    printf '%s\n' "$requested" > "$temporary"
    mv -f "$temporary" "$state_dir/hdmi-target"
    previous=$(current_target)
    previous_unit=$(unit_for "$previous")
    # Discover before releasing the current input route; HDMI has already switched.
    if ! expected_remote=$(prepare_target "$requested"); then
      echo 'HDMI 已切换；未找到目标电脑，保留当前控制通道。' >&2
      exit 1
    fi
    runtime_remote=$(python3 - "$runtime/desktop-drag/config" <<'REMOTE'
import json,sys
try: print(json.load(open(sys.argv[1]))['remote'])
except (OSError,ValueError,KeyError): pass
REMOTE
)
    if [[ "$requested" != "$previous" || "$runtime_remote" != "$expected_remote" ]] || ! systemctl --user is-active --quiet "$requested_unit"; then
      systemctl --user stop "$previous_unit"
      if ! systemctl --user restart "$requested_unit" || ! wait_ready "$requested" "$expected_remote"; then
        systemctl --user stop "$requested_unit" || true
        systemctl --user start "$previous_unit" || true
        echo 'HDMI 已切换；Viewflow 连接失败，已尝试恢复原控制目标。' >&2
        exit 1
      fi
    fi
    # Remember the selected input route across login/reboot.
    systemctl --user enable "$requested_unit" >/dev/null
    if [[ "$previous_unit" != "$requested_unit" ]]; then
      systemctl --user disable "$previous_unit" >/dev/null
    fi
    temporary=$(mktemp "$state_dir/.viewflow-target.XXXXXX")
    printf '%s\n' "$requested" > "$temporary"
    mv -f "$temporary" "$state_dir/viewflow-target"
    cat "$state_dir/hdmi-target"
    ;;
  *) echo "Usage: $0 {status|set windows|set macos}" >&2; exit 2 ;;
esac
