# Viewflow macOS installer

The public disk image contains one `Viewflow.app`, its bundled helpers and
CoreHID receiver, plus the standard `/Applications` shortcut. It requires macOS
26 or later. No DriverKit extension is included in the CoreHID package. Finder layout is written
without scripting Finder or changing focus. Artwork is rendered at 2x density;
the background's logical size is 760 x 500 points.

For public distribution, first build from the intended release commit using
Xcode with the macOS 26 SDK, Rust, CMake, and the Python pairing dependencies.
The build does not install or launch the application. Use a Developer ID
Application identity, an all-devices Developer ID profile for the CoreHID
receiver, and an existing `notarytool` Keychain profile. Keep credentials out of
commands, logs and the repository. The signing certificate must be included in
the receiver profile, which must grant `com.apple.developer.hid.virtual.device`.

```sh
python tools/build-macos-app.py \
  --output dist/Viewflow.app --arch arm64 --distribution \
  --identity 'Developer ID Application: <name> (<team>)' \
  --corehid-profile /path/to/CoreHID-Developer-ID.provisionprofile \
  --corehid-bundle-id org.viewflow.trackpad-corehid-probe
```

Install `ds-store` and `mac-alias` in the same Python virtual environment, then:

```sh
python tools/package-macos-dmg.py \
  --app dist/Viewflow.app --distribution \
  --identity 'Developer ID Application: <name> (<team>)' \
  --notary-profile '<existing Keychain profile name>' \
  --output dist/Viewflow-macOS-arm64.dmg
```

This preserves the supplied app's identifier, entitlements and embedded receiver
signature. It adds the icon, refreshes artifact hashes, signs the container app
and DMG, verifies the embedded signature and disk-image checksum, and writes a
SHA-256 sidecar. Use an Apple Silicon app with the current artwork. No pairing
files, private keys, developer checkout, or user settings are packaged.

Public mode rejects development signing, registered-device profiles, debug
entitlements, mismatched signing teams/certificates and legacy driver payloads.
It notarizes and staples both the app and DMG and requires Gatekeeper assessment
to pass. Public mode requires `--notary-profile`; errors stop the release.
The source builder also accepts `--distribution --dmg --notary-profile NAME`.
The source app output is signed; the app inside the DMG is the finalized,
stapled copy. Use `--prepared-app` on the packager to retain that copy separately.

Before uploading, mount the resulting DMG without opening Finder, verify the
embedded app with `codesign --verify --deep --strict`, `xcrun stapler validate`
and `spctl --assess --type execute`, inspect the bundled source revision and
hashes, then unmount. Upload the DMG and its `.dmg.sha256` sidecar to the matching
GitHub release. Record the accepted app and DMG notarization IDs in the release
evidence. Signing, fake-device tests and Gatekeeper checks do not establish live
mouse, keyboard or gesture acceptance; those checks remain user-operated.

Development packaging without `--distribution` remains available for local
testing and is not a public release. Legacy DriverKit packaging requires
`--hid-backend driverkit` explicitly. Do not replace an active installation as
part of building or inspecting an artifact.

Hosted macOS CI validates native pixels and portable behavior but omits the
`hardware-codec` CTest label: the hosted VM returned VideoToolbox session error
`-12903`, while the actual Mac passed the hardware codec fixture. CI's unsigned
no-HID build uses `--skip-hardware-tests` and records
`hardware_codec_tested: false` in its manifest. Signed builds reject that flag
and run the complete suite, including H.264/HEVC encode/decode. CI artifacts
therefore cannot stand in for the public release checks.

`tools/cleanup-macos-legacy.py` prints its migration plan by default. `--apply`
disables the explicitly listed legacy jobs, archives retired Viewflow bundles
and launch agents, verifies the archive, and removes their original install
entries. It preserves `/Applications/Viewflow.app`, pairing data, current runtime
helpers, source checkouts, and the active system extension.

The application and mounted-volume icons now come from
`platform/branding/Viewflow.icns`, generated from the approved Linux SVG.
`render-assets.swift` renders the Finder background only.
