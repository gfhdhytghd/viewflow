#!/usr/bin/env python3
"""Build one self-contained Viewflow.app. Full HID packaging is the default.

Runs on macOS with Xcode and Rust. Never installs, launches, posts input, or
changes permissions. --without-driver produces an explicitly incomplete dev app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_SOURCE = ROOT / 'platform/macos-app'
HELPERS = ('viewflowd', 'vf-window-peer', 'vf-clipboard-peer',
           'viewflow-macos-windows', 'viewflow-macos-probe')
DRIVER_ID = 'org.viewflow.trackpad-probe'
APP_ID = 'org.viewflow.app'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(args):
    return run(args, stdout=subprocess.PIPE, text=True).stdout.strip()


def require_file(path):
    if not path.is_file():
        raise ValueError(f'missing required component: {path}')


def inspect_bundle(app, require_driver=True, app_id=APP_ID):
    """Structural check is portable; native architecture/signature checks follow."""
    contents = app / 'Contents'
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != app_id or info.get('CFBundleExecutable') != 'Viewflow':
        raise ValueError('incorrect app identity or executable')
    binaries = [contents / 'MacOS/Viewflow'] + [contents / 'Helpers' / x for x in HELPERS]
    for binary in binaries:
        require_file(binary)
        if not os.access(binary, os.X_OK):
            raise ValueError(f'component is not executable: {binary}')
    driver = contents / 'Library/SystemExtensions' / (DRIVER_ID + '.dext')
    if require_driver or driver.exists():
        require_file(driver / 'Info.plist')
        driver_info = plistlib.loads((driver / 'Info.plist').read_bytes())
        if driver_info.get('CFBundleIdentifier') != DRIVER_ID:
            raise ValueError('wrong HID driver bundle identity')
        executable = driver_info.get('CFBundleExecutable', '')
        if not executable or Path(executable).name != executable:
            raise ValueError('invalid driver executable')
        require_file(driver / executable)
        binaries.append(driver / executable)
    return binaries


def copy_payload(app, app_binary, helper_dir, driver, app_id=APP_ID):
    contents = app / 'Contents'
    for directory in ('MacOS', 'Helpers', 'Resources'):
        (contents / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(APP_SOURCE / 'Info.plist', contents / 'Info.plist')
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    info['CFBundleIdentifier'] = app_id
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(app_binary, contents / 'MacOS/Viewflow')
    shutil.copy2(ROOT / 'platform/windows-composition-preview/Hyprland-LICENSE',
                 contents / 'Resources/Hyprland-LICENSE')
    for helper in HELPERS:
        require_file(helper_dir / helper)
        shutil.copy2(helper_dir / helper, contents / 'Helpers' / helper)
    if driver:
        destination = contents / 'Library/SystemExtensions' / (DRIVER_ID + '.dext')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(driver, destination, symlinks=True)
    inspect_bundle(app, require_driver=driver is not None, app_id=app_id)


def validate_profile(profile, app_id, driver_allows_any=False):
    decoded = plistlib.loads(run(['security', 'cms', '-D', '-i', profile], stdout=subprocess.PIPE).stdout)
    entitlements = decoded.get('Entitlements', {})
    identifier = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier', ''))
    team = entitlements.get('com.apple.developer.team-identifier', '')
    if not team or identifier != f'{team}.{app_id}':
        raise ValueError(f'provisioning profile does not explicitly cover {app_id}')
    if not entitlements.get('com.apple.developer.system-extension.install'):
        raise ValueError('host profile lacks system-extension.install')
    if not driver_allows_any and DRIVER_ID not in entitlements.get('com.apple.developer.driverkit.userclient-access', []):
        raise ValueError('host profile lacks Viewflow DriverKit userclient-access')
    import datetime
    expiry = decoded.get('ExpirationDate')
    if expiry is None or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('host provisioning profile is expired')
    return team


def build(args, work):
    arch = args.arch
    target = {'arm64': 'aarch64-apple-darwin', 'x86_64': 'x86_64-apple-darwin'}[arch]
    helper_dir = work / 'helpers'; helper_dir.mkdir()
    run(['cargo', 'build', '--locked', '--release', '--target', target, '-p', 'viewflowd',
         '--bin', 'viewflowd', '--bin', 'vf-window-peer', '--bin', 'vf-clipboard-peer'], cwd=ROOT)
    target_dir = Path(json.loads(output(['cargo', 'metadata', '--no-deps', '--format-version', '1', '--manifest-path', ROOT / 'Cargo.toml']))['target_directory'])
    for helper in HELPERS[:3]:
        shutil.copy2(target_dir / target / 'release' / helper, helper_dir / helper)
    native = work / 'native'
    run(['cmake', '-S', ROOT / 'platform/macos', '-B', native,
         f'-DCMAKE_OSX_ARCHITECTURES={arch}', '-DCMAKE_BUILD_TYPE=Release'])
    run(['cmake', '--build', native, '--config', 'Release', '--parallel'])
    run(['ctest', '--test-dir', native, '--output-on-failure'])
    for helper in HELPERS[3:]:
        shutil.copy2(native / helper, helper_dir / helper)
    app_binary = work / 'Viewflow'
    sdk = output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    backdrop_object = work / 'menu-backdrop-probe.o'
    run(['xcrun', 'clang++', '-std=c++20', '-fobjc-arc', '-DVIEWFLOW_BACKDROP_EMBEDDED',
         '-target', f'{arch}-apple-macosx13.0', '-isysroot', sdk, '-c',
         ROOT / 'platform/macos/menu_backdrop_probe.mm', '-o', backdrop_object])
    sources = sorted((APP_SOURCE / 'Sources').glob('*.swift'))
    sources.append(ROOT / 'platform/macos-trackpad-probe/VFTrackpadHost/VFTrackpadHost/TrackpadBridge.swift')
    run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library',
         '-target', f'{arch}-apple-macosx13.0', '-sdk', sdk, *sources, backdrop_object,
         '-lc++', '-framework', 'ScreenCaptureKit',
         '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'IOKit',
         '-framework', 'ApplicationServices', '-framework', 'SystemExtensions',
         '-framework', 'ServiceManagement', '-o', app_binary])
    driver = args.driver_bundle
    if not args.without_driver and driver is None:
        if args.identity:
            raise ValueError('signed full app requires --driver-bundle with a provisioned, signed DEXT')
        if arch != 'arm64':
            raise ValueError('current HID project supports arm64; supply a matching --driver-bundle or explicitly use --without-driver')
        derived = work / 'driver'
        run(['xcodebuild', '-project', ROOT / 'platform/macos-trackpad-probe/VFTrackpadProbe.xcodeproj',
             '-target', 'VFTrackpadProbe', '-configuration', 'Debug', '-sdk', 'driverkit',
             f'SYMROOT={derived}', 'CODE_SIGNING_ALLOWED=NO', f'ARCHS={arch}', 'build'])
        candidates = list(derived.rglob(DRIVER_ID + '.dext'))
        if len(candidates) != 1:
            raise ValueError('could not locate exactly one built HID driver')
        driver = candidates[0]
    return app_binary, helper_dir, driver


def package(args):
    if sys.platform != 'darwin':
        raise ValueError('native app compilation/signing requires macOS with Xcode; no Mac connection is attempted')
    destination = args.output.resolve()
    if destination.suffix != '.app' or destination.exists():
        raise ValueError('--output must be a new .app path (existing app is never overwritten)')
    if getattr(args, "dmg", False) and (not args.identity or args.without_driver):
        raise ValueError("--dmg requires the full signed application")
    if args.without_driver and (args.driver_bundle or args.identity or args.app_profile):
        raise ValueError('--without-driver is an explicitly unsigned development build only')
    if args.identity and not args.app_profile:
        raise ValueError(f'signed full app requires --app-profile for {args.bundle_id}')
    if args.app_profile and not args.identity:
        raise ValueError('--app-profile requires --identity')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.viewflow-build-', dir=destination.parent) as temporary:
        work = Path(temporary)
        app_binary, helper_dir, driver = build(args, work)
        app = work / 'Viewflow.app'
        copy_payload(app, app_binary, helper_dir, driver, args.bundle_id)
        binaries = inspect_bundle(app, require_driver=not args.without_driver, app_id=args.bundle_id)
        for binary in binaries:
            run(['lipo', '-verify_arch', args.arch, binary])
            # Reject accidentally linking a developer's Homebrew/build directory.
            for line in output(['otool', '-L', binary]).splitlines()[1:]:
                dependency = line.strip().split(' (', 1)[0]
                if dependency and not dependency.startswith(('/System/Library/', '/usr/lib/', '/System/DriverKit/', '@rpath/', '@loader_path/', '@executable_path/')):
                    raise ValueError(f'nonportable dependency in {binary.name}: {dependency}')
        contents = app / 'Contents'
        signed_driver = contents / 'Library/SystemExtensions' / (DRIVER_ID + '.dext')
        entitlements = plistlib.loads((APP_SOURCE / 'Viewflow.entitlements').read_bytes())
        if args.identity:
            run(['codesign', '--verify', '--strict', '--verbose=2', signed_driver])
            driver_entitlements = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', signed_driver],
                                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout)
            driver_allows_any = driver_entitlements.get('com.apple.developer.driverkit.allow-any-userclient-access') is True
            team = validate_profile(args.app_profile, args.bundle_id, driver_allows_any)
            if driver_allows_any:
                # Preserve the already signed driver's policy, never add this
                # entitlement or modify the driver to avoid host provisioning.
                entitlements.pop('com.apple.developer.driverkit.userclient-access', None)
            signature = run(['codesign', '-dv', '--verbose=4', signed_driver], stderr=subprocess.PIPE, text=True).stderr
            if f'TeamIdentifier={team}' not in signature.splitlines():
                raise ValueError('app and embedded HID driver must use the same development team')
            require_file(signed_driver / 'embedded.provisionprofile')
            shutil.copy2(args.app_profile, contents / 'embedded.provisionprofile')
            entitlements['com.apple.application-identifier'] = f'{team}.{args.bundle_id}'
            entitlements['com.apple.developer.team-identifier'] = team
        entitlement_file = work / 'host-entitlements.plist'
        entitlement_file.write_bytes(plistlib.dumps(entitlements))
        identity = args.identity or '-'
        signing = ['--force', '--sign', identity]
        if args.identity:
            signing += ['--options', 'runtime', '--timestamp']
        for helper in HELPERS:
            run(['codesign', *signing, '--identifier', f'{args.bundle_id}.helper.{helper}', contents / 'Helpers' / helper])
        if driver and not args.identity:
            # Development packaging only. Ad-hoc signing does not enable DriverKit.
            run(['codesign', '--force', '--sign', '-', signed_driver])
        snapshot = ROOT / 'source-build.json'
        source = json.loads(snapshot.read_text(encoding='utf-8')) if snapshot.is_file() else {
            'revision': output(['git', '-C', ROOT, 'rev-parse', 'HEAD']),
            'dirty': bool(output(['git', '-C', ROOT, 'status', '--porcelain']))}
        manifest = {'schema_version': 1, 'bundle_id': args.bundle_id, 'architecture': args.arch,
                    'signing': 'identity' if args.identity else 'ad-hoc',
                    'hid_included': driver is not None, 'native_permissions_verified': False,
                    'git_revision': source['revision'],
                    'workspace_dirty': source['dirty'],
                    'helpers': {name: hashlib.sha256((contents / 'Helpers' / name).read_bytes()).hexdigest() for name in HELPERS}}
        (contents / 'Resources/build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        run(['codesign', *signing, '--entitlements', entitlement_file, app])
        run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
        inspect_bundle(app, require_driver=not args.without_driver, app_id=args.bundle_id)
        app.rename(destination)
    if getattr(args, "dmg", False):
        run([sys.executable, ROOT / "tools/package-macos-dmg.py", "--app", destination,
             "--output", destination.with_suffix(".dmg"), "--identity", args.identity])
    if args.zip:
        archive = destination.with_suffix('.zip')
        if archive.exists():
            raise ValueError(f'app built, but archive already exists: {archive}')
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', destination, archive])
    print(json.dumps({'app': str(destination), 'hid_included': not args.without_driver,
                      'signed_identity': bool(args.identity), 'permissions_verified': False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/Viewflow.app')
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--driver-bundle', type=Path)
    parser.add_argument('--without-driver', action='store_true', help='explicit incomplete development build; cannot validate HID')
    parser.add_argument('--identity', help='codesign identity; requires provisioned host and pre-signed HID driver')
    parser.add_argument('--app-profile', type=Path)
    parser.add_argument('--bundle-id', default=APP_ID, help='stable provisioned app identity, including an existing Viewflow host identity')
    parser.add_argument('--zip', action='store_true')
    parser.add_argument('--dmg', action='store_true', help='also create the signed drag-to-install disk image')
    args = parser.parse_args()
    try:
        package(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Viewflow app build: {error}\n')


if __name__ == '__main__':
    main()
