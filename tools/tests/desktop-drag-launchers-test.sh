#!/usr/bin/env bash
# Hermetic launcher test: no real compositor, socket, plugin, or peer is used.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runtime" "$tmp/plugins"
export XDG_RUNTIME_DIR="$tmp/runtime"
export TEST_LOG="$tmp/commands.log"
export TEST_STATE="$tmp/fake-state"
export HYPRCTL="$tmp/bin/hyprctl"
export HYPRLAND_INSTANCE_SIGNATURE='test-instance'
touch "$tmp/plugins/capture.so" "$tmp/plugins/input.so"

cat >"$tmp/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${TEST_LOG:?}; state=${TEST_STATE:?}
printf '%q ' "$@" >>"$log"; printf '\n' >>"$log"
initial='[{"name":"DP-4","activeWorkspace":{"id":1},"specialWorkspace":{"id":0,"name":""},"x":0,"y":0,"width":2000,"height":1000,"scale":2,"transform":0}]'
monitors() {
  if [[ -e "$state/output-created" ]]; then
    local special='{"id":0,"name":""}'
    local active='{"id":2,"name":"2"}'
    if [[ -e "$state/special-workspace" ]]; then
      special='{"id":-99,"name":"special:viewflow"}'
      active='{"id":-100,"name":"viewflow-underlay"}'
    fi
    if [[ ${TEST_ZERO_OUTPUT:-0} == 1 ]]; then
      printf '%s\n' "$initial" | jq --argjson active "$active" --argjson special "$special" '. + [{"id":99,"name":"HEADLESS-99","activeWorkspace":$active,"specialWorkspace":$special,"x":1000,"y":0,"width":0,"height":0,"scale":1}]'
      return
    fi
    printf '%s\n' "$initial" | jq --argjson active "$active" --argjson special "$special" '. + [{"id":99,"name":"HEADLESS-99","activeWorkspace":$active,"specialWorkspace":$special,"x":1000,"y":0,"width":800,"height":500,"scale":1,"transform":0}]'
  else printf '%s\n' "$initial"; fi
}
plugins() {
  if [[ -f "$state/plugins" ]]; then cat "$state/plugins"; else printf '%s\n' '[{"filename":"/opt/hyprcapture.so"}]'; fi
}
if [[ $1 == -j && $2 == monitors ]]; then monitors; exit 0; fi
if [[ $1 == -j && $2 == instances ]]; then printf '%s\n' '[{"instance":"test-instance","pid":987}]'; exit 0; fi
if [[ $1 == -j && $2 == clients ]]; then
  if [[ -e "$state/output-created" ]]; then printf '%s\n' '[{"mapped":true,"floating":true,"hidden":false,"workspace":{"id":1},"at":[1000,0],"size":[10,10],"address":"0x1a"}]'; else printf '%s\n' '[]'; fi
  exit 0
fi
if [[ $1 == -j && $2 == plugin && $3 == list ]]; then plugins; exit 0; fi
if [[ $1 == output && $2 == create && $3 == headless ]]; then mkdir -p "$state"; : >"$state/output-created"; exit 0; fi
if [[ $1 == output && $2 == remove && $3 == HEADLESS-99 ]]; then rm -f "$state/output-created" "$state/special-workspace"; exit 0; fi
if [[ $1 == eval ]]; then
  if [[ $2 == *'hl.monitor('* ]]; then
    [[ $2 == *'position = "1000x0"'* ]] || exit 4
  elif [[ $2 == *'monitor:set_special_workspace("viewflow")'* ]]; then
    [[ $2 == *'monitor:set_workspace("name:viewflow-underlay")'* ]] || exit 4
    : >"$state/special-workspace"
  else
    exit 4
  fi
  exit 0
fi
if [[ $1 == plugin && $2 == load ]]; then
  mkdir -p "$state"
  if [[ -f "$state/plugins" ]]; then jq --arg p "$3" '. + [{filename:$p}]' "$state/plugins" >"$state/next"; mv "$state/next" "$state/plugins"
  else jq -n --arg p "$3" '[{filename:"/opt/hyprcapture.so"},{filename:$p}]' >"$state/plugins"; fi
  exit 0
fi
if [[ $1 == plugin && $2 == unload ]]; then
  jq --arg p "$3" 'map(select(.filename != $p))' "$state/plugins" >"$state/next"; mv "$state/next" "$state/plugins"; exit 0
fi
printf 'unexpected fake hyprctl invocation\n' >&2; exit 9
EOF
cat >"$tmp/peer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $1 == probe ]]; then
  [[ $2 == --compositor-pid && $3 == 987 && $4 == --window && $5 == 0x1a ]] || exit 7
  printf '%s\n' '{"width":640,"height":480,"geometry_epoch":7,"logical":{"x":1,"y":2,"width":3,"height":4},"address":"0x1a","pid":123,"stable_id":"org.example.test"}'
  exit 0
fi
if [[ $1 == validate-send && $2 == --config ]]; then
  jq -e '(.desktop.candidates[0].address == "0x1a" and .windows[0].width == 640) or (.desktop.auto_enroll == true and .windows == [] and .desktop.candidates == [])' "$3" >/dev/null
  exit 0
fi
[[ $1 == send && $2 == --config ]] || exit 8
sleep 30
EOF
chmod +x "$tmp/bin/hyprctl" "$tmp/peer"

cat >"$tmp/source.json" <<EOF
{
  "compositor_pid": 987,
  "pointer": {"native_socket": "$tmp/runtime/viewflow/hyprland.sock"},
  "desktop": {
    "hyprland_socket": "$tmp/runtime/hypr/test-instance/.socket.sock",
    "native_control_dir": "$tmp/runtime/viewflow/control",
    "local_display": {"x": 0, "y": 0, "width": 2000, "height": 1000, "scale": 2},
    "remote_display": {"x": 1000, "y": 0, "width": 800, "height": 500, "scale": 1},
    "candidates": []
  },
  "media": {"stream_id":"00000000000000000000000000000063", "width":4096, "height":4096},
  "windows": []
}
EOF

"$root/tools/desktop-drag-linux.sh" start \
  --config "$tmp/source.json" --monitor DP-4 --window 0x1a --peer "$tmp/peer" \
  --capture-plugin "$tmp/plugins/capture.so" --input-plugin "$tmp/plugins/input.so" \
  --state-dir "$tmp/runtime/owned"
[[ -e "$tmp/runtime/owned/daemon.pid" ]]
rg -q 'output create headless' "$TEST_LOG"
rg -q 'eval .*hl\.monitor' "$TEST_LOG"
rg -q 'eval .*set_special_workspace.*viewflow' "$TEST_LOG"
rg -q 'eval .*set_workspace.*viewflow-underlay' "$TEST_LOG"
[[ $(rg -c 'plugin load' "$TEST_LOG") == 2 ]]
! rg -q 'keyword' "$TEST_LOG"
jq -e '.pointer.cursor_monitor_id == 99 and .desktop.candidates[0].stable_id == "org.example.test" and .windows[0].width == 640 and .windows[0].geometry_epoch == 7' "$tmp/runtime/owned/config" >/dev/null

"$root/tools/desktop-drag-linux.sh" stop --state-dir "$tmp/runtime/owned"
rg -q 'output remove HEADLESS-99' "$TEST_LOG"
[[ $(rg -c 'plugin unload' "$TEST_LOG") == 2 ]]
jq -e 'length == 1 and .[0].filename == "/opt/hyprcapture.so"' "$TEST_STATE/plugins" >/dev/null

"$root/tools/desktop-drag-linux.sh" start \
  --config "$tmp/source.json" --monitor DP-4 --crossing-timeout 1 --peer "$tmp/peer" \
  --capture-plugin "$tmp/plugins/capture.so" --input-plugin "$tmp/plugins/input.so" \
  --state-dir "$tmp/runtime/owned"
rg -q -- '-j clients' "$TEST_LOG"
"$root/tools/desktop-drag-linux.sh" stop --state-dir "$tmp/runtime/owned"

"$root/tools/desktop-drag-linux.sh" start \
  --config "$tmp/source.json" --monitor DP-4 --empty-desktop --peer "$tmp/peer" \
  --capture-plugin "$tmp/plugins/capture.so" --input-plugin "$tmp/plugins/input.so" \
  --state-dir "$tmp/runtime/owned"
jq -e '.windows == [] and .desktop.candidates == [] and .desktop.auto_enroll and .pointer.cursor_monitor_id == 99' "$tmp/runtime/owned/config" >/dev/null
"$root/tools/desktop-drag-linux.sh" stop --state-dir "$tmp/runtime/owned"

loads_before=$(rg -c 'plugin load' "$TEST_LOG")
if TEST_ZERO_OUTPUT=1 "$root/tools/desktop-drag-linux.sh" start \
    --config "$tmp/source.json" --monitor DP-4 --window 0x1a --peer "$tmp/peer" \
    --capture-plugin "$tmp/plugins/capture.so" --input-plugin "$tmp/plugins/input.so" \
    --state-dir "$tmp/runtime/owned" >"$tmp/zero-output.log" 2>&1; then
  printf 'zero-size virtual output was accepted\n' >&2; exit 1
fi
rg -q 'usable dimensions' "$tmp/zero-output.log"
[[ ! -e "$TEST_STATE/output-created" ]]
[[ $(rg -c 'plugin load' "$TEST_LOG") == "$loads_before" ]]

PATH="$tmp/bin:$PATH" "$root/tools/desktop-drag-pair.sh" prepare --dir "$tmp/pair" --monitor DP-4 \
  --linux-ip 192.0.2.10 --windows-host viewflow-windows --windows-ip 192.0.2.20 \
  --windows-resolution 800x500 --windows-scale 1 --windows-position 1000x0 >/dev/null
[[ $(stat -c '%a' "$tmp/pair") == 700 ]]
[[ $(stat -c '%a' "$tmp/pair/source.key") == 600 ]]
[[ $(stat -c '%a' "$tmp/pair/receiver.key") == 600 ]]
jq -e '.desktop.remote_display == {x:1000,y:0,width:800,height:500,scale:1} and .desktop.hyprland_socket == "'"$tmp"'/runtime/hypr/test-instance/.socket.sock" and .occlusion == "opaque" and .media.width == 1024 and .media.max_width == 8192 and .media.max_height == 4096 and .media.max_encoded_bytes == 134217728 and .windows == []' "$tmp/pair/send.json" >/dev/null
jq -e '.desktop.display.x == 1000 and .desktop.display.width == 800 and .width == 1024 and .max_width == 8192 and .max_height == 4096 and .max_encoded_bytes == 134217728 and .max_decoded_bytes == 268435456' "$tmp/pair/receive.json" >/dev/null
PATH="$tmp/bin:$PATH" "$root/tools/desktop-drag-pair.sh" prepare --dir "$tmp/left-pair" --monitor DP-4 \
  --linux-ip 192.0.2.10 --windows-host viewflow-windows --windows-ip 192.0.2.20 \
  --windows-resolution 1920x1080 --windows-scale 1.5 --windows-position -1280x40 >/dev/null
jq -e '.desktop.remote_display == {width:1920,height:1080,scale:1.5,x:-1280,y:40}' "$tmp/left-pair/send.json" >/dev/null
jq -e '.desktop.display == {width:1920,height:1080,scale:1.5,x:-1280,y:40}' "$tmp/left-pair/receive.json" >/dev/null
printf 'desktop drag launcher hermetic test passed\n'
