# Magic Trackpad → macOS DriverKit first feasibility gate

2026-09-07 session, user request: start trying Linux-connected Magic Trackpad
multifinger input on M4/macOS 27. No input injection or focus changes performed.

## Verified

- LAN Mac: macOS 27.0 / 26A5425a, arm64; DriverKit27.0 SDK in Xcode Beta.
- Linux: Apple Inc. Magic Trackpad, Bluetooth HID ID `0005:004C:0324`, currently
  `/dev/input/event17` (not a stable identity). Kernel exports 16 tracking slots;
  that is a capacity, not a claim of 16 simultaneous usable fingers.
- X range -3678..3934 (47 units/mm); Y -2478..2587 (44 units/mm), pressure
  0..253, touch major/minor 0..1020 and orientation -3..4. Queried metadata only;
  no real finger stream was recorded. Descriptor is 135 bytes; see
  [inventory](linux-inventory.json) for bytes and hash.
- Own generic five-contact HID descriptor parsed by `hid-tools`: Digitizers /
  Touch Pad application, five Contact ID fields, input report 1 length 32 bytes.
- `platform/macos-trackpad-probe/build.sh`: **BUILD SUCCEEDED**, unsigned Mach-O
  arm64 DEXT. Local C++ warnings are treated as errors. This checks compilation
  and linking, not runtime service creation or gestures.
- Signed Xcode build without portal updates: **BUILD FAILED** with:
  `requires a provisioning profile with the DriverKit (development) and DriverKit Family HID Device (development) features`.
- The Mac has one usable Apple Development signing identity. Three locally
  installed profiles have no DriverKit/HID grants. This does not prove that the
  developer account lacks permissions elsewhere or could not request them.

Remote build directory: `/Users/linhaikuo/viewflow-trackpad-probe`.
Unsigned artifact: `build/Debug-driverkit/org.viewflow.trackpad-probe.dext`.
Build and signing logs are in that remote directory. Binary hash and exact
signing error are recorded in [build-result.txt](build-result.txt).

## Not established

No DEXT was signed, installed or activated. No virtual device was enumerated at
runtime. No native gesture, animation, contact submission, transport integration,
pressure or haptic functionality is verified. The prototype intentionally has
no input submission path yet. The signing profile is the first concrete blocker;
provisioning it does not guarantee Apple gesture compatibility.

Existing Viewflow code, active services, system security settings, signing
profiles and unrelated working-tree changes were left untouched. Prototype
sources and artifacts were copied to their own directory on the Mac.
