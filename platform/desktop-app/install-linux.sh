#!/bin/sh
set -eu
# User installation only. This does not load plugins, access input, or start peers.
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base="${XDG_DATA_HOME:-$HOME/.local/share}"
target="$base/viewflow/app"
if [ -e "$target" ]; then
    echo "Viewflow is already installed at $target. Close it and move that directory aside before installing this build." >&2
    exit 1
fi
mkdir -p "$base/viewflow" "$base/applications"
cp -R -- "$source_dir" "$target"
# Desktop Entry Exec escaping is performed by the bundled Python runtime.
"$target/Viewflow" --install-desktop-entry
printf 'Installed Viewflow at %s\nOpen Viewflow from the application menu.\n' "$target"
