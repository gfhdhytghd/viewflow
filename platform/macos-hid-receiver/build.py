#!/usr/bin/env python3
"""Build a separate signed receiver; never install, launch, or submit input."""
import argparse
import datetime
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parent
CAPABILITY = 'com.apple.developer.hid.virtual.device'


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def profile_entitlements(decoded, bundle_id):
    entitlements = decoded.get('Entitlements', {})
    team = entitlements.get('com.apple.developer.team-identifier')
    identifier = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier'))
    if not team or identifier != f'{team}.{bundle_id}':
        raise ValueError('profile must explicitly cover the selected bundle ID and team')
    if entitlements.get(CAPABILITY) is not True:
        raise ValueError(f'profile lacks {CAPABILITY}; enable the capability and regenerate the profile')
    expiry = decoded.get('ExpirationDate')
    if expiry is None or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('provisioning profile is expired or has no expiry')
    return {CAPABILITY: True, 'com.apple.application-identifier': identifier,
            'com.apple.developer.team-identifier': team}


def build(args):
    if sys.platform != 'darwin':
        raise ValueError('build on macOS 26 or later with full Xcode and the macOS 26+ SDK')
    destination = args.output.resolve()
    if destination.suffix != '.app' or destination.exists():
        raise ValueError('--output must be a new .app path')
    decoded = plistlib.loads(run(['security', 'cms', '-D', '-i', args.profile], stdout=subprocess.PIPE).stdout)
    entitlements = profile_entitlements(decoded, args.bundle_id)
    if args.distribution:
        sys.path.insert(0, str(SOURCE.parents[1] / 'tools'))
        from macos_distribution import validate_distribution_profile
        validate_distribution_profile(decoded, args.bundle_id)
    sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], stdout=subprocess.PIPE, text=True).stdout.strip()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.viewflow-hid-build-', dir=destination.parent) as temporary:
        work = Path(temporary)
        app = work / 'ViewflowHIDReceiver.app'
        contents = app / 'Contents'
        binaries = contents / 'MacOS'
        binaries.mkdir(parents=True)
        info = {'CFBundleIdentifier': args.bundle_id, 'CFBundleExecutable': 'ViewflowHIDReceiver',
                'CFBundleName': 'Viewflow HID Receiver', 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1.0',
                'LSMinimumSystemVersion': '26.0', 'LSUIElement': True}
        info['ViewflowHIDServiceVersion'] = 1
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        shutil.copy2(args.profile, contents / 'embedded.provisionprofile')
        entitlement_file = work / 'entitlements.plist'
        entitlement_file.write_bytes(plistlib.dumps(entitlements))
        target = f'{args.arch}-apple-macosx26.0'
        native = work / 'NativeBridge.o'
        run(['xcrun', 'clang++', '-std=c++17', '-O2', '-target', target, '-isysroot', sdk,
             '-c', SOURCE / 'NativeBridge.cpp', '-o', native])
        bridge = SOURCE.parent / 'macos-trackpad-probe/VFTrackpadHost/VFTrackpadHost/TrackpadBridge.swift'
        run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library', '-target', target,
             '-sdk', sdk, '-import-objc-header', SOURCE / 'NativeBridge.h', SOURCE / 'Main.swift',
             SOURCE / 'SharedInput.swift', SOURCE.parent / 'macos-app/Sources/HIDServer.swift',
             bridge, native, '-lc++', '-framework', 'CoreHID', '-framework', 'IOKit',
             '-o', binaries / 'ViewflowHIDReceiver'])
        run(['codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp',
             '--entitlements', entitlement_file, app])
        run(['codesign', '--verify', '--strict', '--verbose=2', app])
        signature = run(['codesign', '-dv', '--verbose=4', app], stderr=subprocess.PIPE, text=True).stderr
        if f"TeamIdentifier={entitlements['com.apple.developer.team-identifier']}" not in signature.splitlines():
            raise ValueError('signing identity and provisioning profile belong to different teams')
        signed = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', app],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout)
        if any(signed.get(key) != value for key, value in entitlements.items()):
            raise ValueError('signed executable does not contain the requested entitlements')
        if args.distribution:
            from macos_distribution import verify_developer_id, verify_profile_certificate
            verify_developer_id(app)
            verify_profile_certificate(decoded, app)
        # Keep the completed bundle on the same filesystem; existing installs are untouched.
        if destination.exists():
            raise ValueError('output appeared during build; refusing to replace it')
        app.rename(destination)
    print(destination)
    print('Built and signature-checked; not launched, notarized, or physically validated.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--bundle-id', default='org.viewflow.hid-receiver')
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--distribution', action='store_true', help='require Developer ID and an all-devices CoreHID profile')
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
