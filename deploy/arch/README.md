# Arch Linux package

Build the current Linux application first, using the system Python interpreter
(a downloaded Python runtime may request an executable stack rejected by the
host glibc):

```sh
uv venv --python /usr/bin/python3 build/pacman-system-venv
uv pip install --python build/pacman-system-venv/bin/python -r platform/desktop-app/requirements.txt
build/pacman-system-venv/bin/python tools/build-desktop-app.py --output dist/Viewflow-linux
python3 tools/build-arch-package.py --bundle dist/Viewflow-linux --output dist/arch --pkgver 0.1.0.r20260921
```

The packager creates a `.pkg.tar.zst`, SHA-256 sidecar and the actual PKGBUILD
recipe. It never installs the package. The application resides in
`/opt/viewflow`, with `/usr/bin/viewflow` and a system desktop entry. Installing
does not start services, load compositor plugins, change pairing, or access
physical input. There are no package install hooks.

This is currently an x86_64 NVIDIA-media build. The package requires only the
base runtime; Hyprland, NVIDIA utilities and SSH are optional dependencies so
the GUI can open before the environment is configured. The GUI checks versions
and lists dependencies but never installs system software or requests elevation.
Plugin ABI checking uses the full build commit in bundle-manifest.json, not a
pacman version pin. A patched Hyprland of the same version can differ in ABI.
AMD/Intel dependency guidance is available, but VA-API media support is not yet
implemented in the native pipeline.
The bundle keeps its own Qt/Python/native user
libraries and must not be stripped after its manifest is generated.

The default native trackpad receiver is
`/Applications/ViewflowHIDReceiver.app/Contents/MacOS/ViewflowHIDReceiver` on the
Mac. `--receiver` can still select an alternate receiver explicitly. Pairing,
routes and user-specific device permissions are not included in the package.

2026-09-21 validation: native source build, bundle hash verification, offscreen
passive UI smoke test, trackpad script `--help`, final archive extraction/hash
verification and desktop-entry validation passed. No installation, plugin load
or live input test was performed. The build records the dirty workspace state.
Namcap reports bundled-runtime/path/stripping warnings rather than a clean
distribution-package audit. Its system Python/Qt dependency suggestions largely
refer to bundled modules; Qt also ships an unused TIFF image plugin whose
`libtiff.so.5` dependency is absent on this build host. TIFF decoding is not
validated. The dashboard smoke test passes without that optional plugin.

The setup GUI is covered by offscreen bilingual rendering, read-only inventory,
status-color and dependency guidance tests. No live input is injected.
