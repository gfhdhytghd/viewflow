# Unified Viewflow applications

Viewflow now has application packaging entry points for macOS, Windows and Linux.
Each package has one application entry point and owns its runtime components.
“One app” does not require merging privileged drivers and ordinary UI code into
one executable. The OS-specific boundaries remain inside the installation.

## Scope and verification

- macOS: native SwiftUI `Viewflow.app`, bundled QUIC input/window/clipboard peers,
  native capture/presentation/probes, and the native HID bridge compiled into the
  main executable. Full packaging requires an embedded DriverKit DEXT.
- Windows: one `Viewflow.exe` dashboard and a per-user Inno Setup installer,
  containing the input/desktop/window/cursor/clipboard peers, native window
  backends, virtual-display management utility and optional lock-screen input
  service installer. Touchpad injection uses the existing Windows system API
  implementation, not a separate Viewflow kernel driver.
- Linux: one dashboard and installation archive, containing peers, native
  Wayland window backends, Hyprland input/capture plugins, GPU encoding support
  and physical Magic Trackpad forwarding. This build targets x86_64 Hyprland
  with NVIDIA EGL/CUDA; the compositor and GPU driver remain host dependencies.

A successful package inventory, compilation or permission probe does not prove a
connected session, real keyboard/mouse delivery, gestures or visual fidelity.
Live input acceptance remains user-operated. Building does not install, load
plugins, change focus, connect to a Mac or post input.

## User flow

1. Install and open Viewflow.
2. Import a `.viewflowconnection` file exported from the existing pairing.
3. Open Permissions and complete the OS permissions needed for chosen features.
4. Start the enabled components. Stop individual components or all connections
   from the same application. Quit waits for worker teardown and held-input
   release. Component crashes retry independently; diagnostic failure does not
   close healthy connections. No 33 ms session deadline is introduced.

macOS offers Screen Recording, Accessibility, DriverKit installation/status and
login-item settings. Actual bundled input/capture processes are checked as well
as the app: a parent app permission is not assumed to cover all helpers.
Windows offers lock-screen input service installation through the normal UAC
prompt, and firewall guidance. Ordinary functionality does not require that
service. Linux offers matching-version Hyprland plugin loading and per-device
input permission guidance. Installers never auto-run physical input tests.

## Build macOS

Requires macOS, Xcode, Rust, CMake and the native build dependencies. Current
DriverKit source targets arm64 / DriverKit 27. The GUI itself targets macOS 13+.

```sh
python3 tools/build-macos-app.py --output dist/Viewflow.app --zip
```

This default creates a full **development** bundle with an ad-hoc signed driver.
Ad-hoc signing does not confer DriverKit entitlements or make the driver usable.
A deployable signed build requires a provisioned, signed DEXT and an app profile
for `org.viewflow.app` with `system-extension.install` and
`driverkit.userclient-access` for `org.viewflow.trackpad-probe`:

```sh
python3 tools/build-macos-app.py --output dist/Viewflow.app --zip \
  --driver-bundle /path/org.viewflow.trackpad-probe.dext \
  --identity 'Apple Development: NAME (TEAM)' \
  --app-profile /path/ViewflowApp.provisionprofile
```

The packager checks profile identity/expiry, driver team, all required files,
architecture and signatures. It signs helpers before the outer app. It does not
change SIP, provisioning policy, system extensions or TCC. Developer ID
notarization/distribution and actual driver activation are separate release
steps; they are not implied by `codesign --verify`.

An existing provisioned Viewflow host can retain its identity with
`--bundle-id org.viewflow.trackpad-probe.host`. When the supplied, already signed
driver already has Apple's approved `allow-any-userclient-access` entitlement,
the host needs only `system-extension.install`; the packager reads the actual
driver signature before using this path. It does not add that entitlement,
re-sign the driver, or broaden the driver's existing access policy. This follows
[Apple's documented user-client behavior](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.allow-any-userclient-access).
Without that signed driver entitlement, the host profile must still contain
`driverkit.userclient-access`.

On a development Mac where SSH signing returns `errSecInternalComponent`, run
the build in the user's authorized graphical login session (for example, a
temporary build LaunchAgent). Do not change keychain access controls or SIP.

`--without-driver` is an explicit incomplete development/CI build, cannot be
combined with identity signing, and must not be presented as the complete app.

## Build Windows and Linux

Build on each target OS. PyInstaller includes the interpreter; end users do not
need to install Python. A Windows package cannot be produced by a Linux
PyInstaller invocation.

```sh
python3 -m pip install pyinstaller==6.22.0
python3 tools/build-desktop-app.py --output dist/Viewflow --installer
```

On Windows run from the native MSVC/Rust build environment, with CMake and Inno
Setup (`ISCC.exe`) on PATH. Output includes `Viewflow-Setup-x64.exe`. Optional
lock-screen service installation copies only the service binary into a protected
Program Files location, preserving the existing service's receiver SID model.
The application installer itself runs per-user. Service installation/removal is
separate from per-user app removal; no existing service is silently deleted.
The optional virtual-display utility still requires an independently signed
vendor display-driver package if that feature is used; this repository does not
contain that third-party driver.

On Linux install the normal native build dependencies (Hyprland headers matching
the running compositor, CUDA, FFmpeg, Wayland, EGL/GLES, libinput, CMake,
`pkg-config`, `patchelf`, and Python with Tk). The output archive includes
`install.sh`, which installs in `$XDG_DATA_HOME/viewflow/app` (default
`~/.local/share/viewflow/app`) and creates one application-menu entry. It does
not replace an existing installation or touch the running desktop.

`--payload DIR` packages an already built complete `bin/` and `plugins/` payload.
Missing components are errors. A Linux prebuilt payload must also include
`hyprland-build.json` describing the actual plugin header version/commit. Windows
payloads may provide required non-system DLLs in `dll/`. Build/package manifests
record component hashes and the source revision plus dirty-tree status.

## Pairing export

No credentials are embedded in the release. Pairing files contain private keys;
transfer them using your normal trusted channel. The exporter creates new files
with mode 0600 and refuses to overwrite existing files.

macOS:

```sh
python3 tools/export-app-connection.py --platform macos --name 'My computers' \
  --certificate /path/device.pem --private-key /path/device.key \
  --authority /path/ca.pem --device-id 00000000000000000000000000000002 \
  --window-peer 192.0.2.10:44220,viewflow-peer \
  --output /private/path/mac.viewflowconnection
```

Windows/Linux preserve their existing desktop/cursor topology configuration in
a version-2 plan. See `platform/desktop-app/example-plan.json`. JSON configs may
reference `${profile}/file.pem`, `${bundle}`, and `${program:NAME}`; the application
expands these to its private profile storage and bundled executable paths.
Executable selection uses the bundle's component IDs; arguments are passed
without a shell. Existing runtime configs can therefore be moved into the app
without redesigning desktop geometry or regenerating identities.

```sh
python3 tools/export-app-connection.py --platform windows --name 'My computers' \
  --plan /path/plan.json --file device.pem=/path/device.pem \
  --file device.key=/path/device.key --file ca.pem=/path/ca.pem \
  --output /private/path/windows.viewflowconnection
```

Use the same flow with `--platform linux`. The native trackpad forwarding plan
uses `program: native-trackpad-forward`, and its `--receiver` should be
`/Applications/Viewflow.app/Contents/MacOS/Viewflow`. The Mac app owns the HID
connection; the SSH-side executable only forwards bytes into its local socket.
Old host tools remain available for existing deployments until explicitly
migrated. No existing autostart services are silently migrated or duplicated.

## Inspiration and public mechanisms

The permission guide follows the visible flow in the official
[Codex Computer Use documentation](https://learn.chatgpt.com/docs/computer-use):
a single place to enable the feature, grant macOS screen/access permissions,
and check settings. Those docs do not publish Codex's internal process or
packaging architecture. Viewflow's helper supervisor and packaging are its own
implementation; Codex-specific app approval restrictions are not copied.

Platform mechanisms:

- [Apple helper embedding](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- [Apple system extension activation](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequest)
- [Apple login items](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [PyInstaller packaging](https://www.pyinstaller.org/en/stable/operating-mode.html)
- [Inno Setup per-user installation](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm)
- [freedesktop desktop entries](https://specifications.freedesktop.org/desktop-entry/latest-single/)

## Development checks

`platform/macos-app/Tests/ConfigurationTests.swift` exercises configuration,
address validation, stable window selection, retry recovery and private identity
storage. It can run with Swift/Foundation on Linux. Swift syntax parsing on
Linux is not macOS framework type checking. macOS CI must build the native UI.

`tools/tests/unified-apps-test.py` exercises complete payload requirements,
profile expansion/import, component recovery, independent stop and teardown,
and credential export without real peers or desktop input. GUI smoke checks
run only on an isolated virtual display; they never start connection components.

The older Launch Services stdio adapter now passes its process ID to the native
Mac window helper. The helper releases its resources when that adapter exits;
a separate teardown watchdog reaps it if an OS callback never completes. This
watchdog begins only after the owner process disappears, not after a late frame.
The unified app normally owns helpers directly through its process supervisor.
