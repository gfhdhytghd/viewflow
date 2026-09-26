#!/usr/bin/env python3
"""Build one self-contained Viewflow.app. CoreHID packaging is the default; DriverKit is an explicit legacy option.

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
           'viewflow-macos-windows', 'viewflow-macos-probe', 'viewflow-window-recall', 'viewflow-pairing')
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
    for name in ('Viewflow.icns', 'viewflow.png', 'viewflow-menu.png', 'viewflow-menu@2x.png'):
        require_file(contents / 'Resources' / name)
    if info.get('CFBundleIconFile') != 'Viewflow.icns':
        raise ValueError('missing Viewflow application icon declaration')
    binaries = [contents / 'MacOS/Viewflow'] + [contents / 'Helpers' / x for x in HELPERS]
    for binary in binaries:
        require_file(binary)
        if not os.access(binary, os.X_OK):
            raise ValueError(f'component is not executable: {binary}')
    backend = info.get('ViewflowHIDBackend', 'driverkit')
    if backend == 'corehid':
        nested = contents / 'Helpers/ViewflowHIDReceiver.app'
        nested_info = plistlib.loads((nested / 'Contents/Info.plist').read_bytes())
        if nested_info.get('CFBundleExecutable') != 'ViewflowHIDReceiver':
            raise ValueError('incorrect CoreHID receiver executable')
        if nested_info.get('ViewflowHIDServiceVersion') != 1:
            raise ValueError('CoreHID receiver lacks the shared service protocol; rebuild it')
        receiver = nested / 'Contents/MacOS/ViewflowHIDReceiver'
        require_file(receiver)
        require_file(nested / 'Contents/embedded.provisionprofile')
        if not os.access(receiver, os.X_OK):
            raise ValueError('CoreHID receiver is not executable')
        if (contents / 'Library/SystemExtensions').exists():
            raise ValueError('CoreHID package must not include legacy system extensions')
        return binaries + [receiver]
    if backend not in ('driverkit', 'none'):
        raise ValueError('unknown HID backend')
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


def copy_payload(app, app_binary, helper_dir, driver, app_id=APP_ID, *, corehid=None, hid_backend='driverkit'):
    contents = app / 'Contents'
    for directory in ('MacOS', 'Helpers', 'Resources'):
        (contents / directory).mkdir(parents=True, exist_ok=True)
    shutil.copy2(APP_SOURCE / 'Info.plist', contents / 'Info.plist')
    info = plistlib.loads((contents / 'Info.plist').read_bytes())
    info['CFBundleIdentifier'] = app_id
    info['ViewflowHIDBackend'] = hid_backend
    if hid_backend == 'corehid':
        info['LSMinimumSystemVersion'] = '26.0'
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    for name in ('Viewflow.icns', 'viewflow.png', 'viewflow-menu.png', 'viewflow-menu@2x.png'):
        shutil.copy2(ROOT / 'platform/branding' / name, contents / 'Resources' / name)
    shutil.copy2(app_binary, contents / 'MacOS/Viewflow')
    shutil.copy2(ROOT / 'platform/windows-composition-preview/Hyprland-LICENSE',
                 contents / 'Resources/Hyprland-LICENSE')
    for helper in HELPERS:
        require_file(helper_dir / helper)
        shutil.copy2(helper_dir / helper, contents / 'Helpers' / helper)
    if corehid:
        shutil.copytree(corehid, contents / 'Helpers/ViewflowHIDReceiver.app', symlinks=True)
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
    run(['ctest', '--test-dir', native, '--output-on-failure',
         *(['-LE', 'hardware-codec'] if args.skip_hardware_tests else [])])
    for helper in HELPERS[3:6]:
        shutil.copy2(native / helper, helper_dir / helper)
    # The native UI talks JSON-lines to a self-contained helper; users do not
    # need Python, pip, Qt or shell commands on the receiving Mac.
    run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile',
         '--name', 'viewflow-pairing', '--distpath', helper_dir,
         '--workpath', work / 'pairing-build', '--specpath', work,
         '--paths', ROOT / 'platform/desktop-app', '--collect-submodules', 'zeroconf',
         '--target-arch', arch,
         *(['--codesign-identity', args.identity] if args.identity else []),
         ROOT / 'platform/desktop-app/pairing_helper.py'])
    run([sys.executable, ROOT / 'tools/tests/managed-owner-test.py'])
    ownership_test = work / 'service-ownership-tests'
    run(['xcrun', 'swiftc', '-parse-as-library',
         APP_SOURCE / 'Sources/Configuration.swift', APP_SOURCE / 'Sources/ServiceOwnership.swift',
         APP_SOURCE / 'Tests/ServiceOwnershipTests.swift', '-o', ownership_test])
    run([ownership_test])
    shared_input_test = work / 'shared-input-tests'
    run(['xcrun', 'swiftc', '-parse-as-library',
         ROOT / 'platform/macos-hid-receiver/SharedInput.swift',
         ROOT / 'platform/macos-hid-receiver/SharedInputTests.swift',
         APP_SOURCE / 'Sources/HIDServer.swift',
         ROOT / 'platform/macos-trackpad-probe/VFTrackpadHost/VFTrackpadHost/TrackpadBridge.swift',
         '-framework', 'IOKit', '-o', shared_input_test])
    run([shared_input_test])
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
    driver = args.driver_bundle if args.hid_backend == 'driverkit' else None
    if args.hid_backend == 'driverkit' and driver is None:
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
    args.hid_backend = 'none' if args.without_driver else args.hid_backend
    if args.skip_hardware_tests and (not args.without_driver or args.identity or args.distribution):
        raise ValueError('--skip-hardware-tests is only for unsigned --without-driver CI builds; release builds require every test')
    if args.hid_backend != 'driverkit' and args.driver_bundle:
        raise ValueError('--driver-bundle requires --hid-backend driverkit')
    if args.hid_backend == 'corehid' and (not args.identity or not (args.corehid_profile or args.corehid_bundle)):
        raise ValueError('CoreHID requires --identity and --corehid-profile (or a signed --corehid-bundle)')
    if args.distribution and (args.hid_backend != 'corehid' or not args.identity):
        raise ValueError('public distribution requires the signed CoreHID backend')
    if args.notary_profile and not (args.distribution and args.dmg):
        raise ValueError('--notary-profile requires --distribution --dmg')
    if args.distribution and args.dmg and not args.notary_profile:
        raise ValueError('public DMG requires --notary-profile')
    if getattr(args, "dmg", False) and (not args.identity or args.hid_backend == 'none'):
        raise ValueError("--dmg requires the full signed application")
    if args.without_driver and (args.driver_bundle or args.identity or args.app_profile):
        raise ValueError('--without-driver is an explicitly unsigned development build only')
    if args.identity and args.hid_backend == 'driverkit' and not args.app_profile:
        raise ValueError(f'signed full app requires --app-profile for {args.bundle_id}')
    if args.app_profile and not args.identity:
        raise ValueError('--app-profile requires --identity')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.viewflow-build-', dir=destination.parent) as temporary:
        work = Path(temporary)
        app_binary, helper_dir, driver = build(args, work)
        app = work / 'Viewflow.app'
        corehid = args.corehid_bundle if args.hid_backend == 'corehid' else None
        if args.hid_backend == 'corehid' and corehid is None:
            corehid = work / 'ViewflowHIDReceiver.app'
            run([sys.executable, ROOT / 'platform/macos-hid-receiver/build.py',
                 '--profile', args.corehid_profile, '--identity', args.identity,
                 '--bundle-id', args.corehid_bundle_id, '--arch', args.arch,
                 '--output', corehid, *(['--distribution'] if args.distribution else [])])
        copy_payload(app, app_binary, helper_dir, driver, args.bundle_id,
                     corehid=corehid, hid_backend=args.hid_backend)
        binaries = inspect_bundle(app, require_driver=args.hid_backend == 'driverkit', app_id=args.bundle_id)
        for binary in binaries:
            run(['lipo', '-verify_arch', args.arch, binary])
            # Reject accidentally linking a developer's Homebrew/build directory.
            for line in output(['otool', '-L', binary]).splitlines()[1:]:
                dependency = line.strip().split(' (', 1)[0]
                if dependency and not dependency.startswith(('/System/Library/', '/usr/lib/', '/System/DriverKit/', '@rpath/', '@loader_path/', '@executable_path/')):
                    raise ValueError(f'nonportable dependency in {binary.name}: {dependency}')
        contents = app / 'Contents'
        signed_driver = contents / 'Library/SystemExtensions' / (DRIVER_ID + '.dext')
        entitlements = plistlib.loads((APP_SOURCE / 'Viewflow.entitlements').read_bytes()) if args.hid_backend == 'driverkit' else {}
        if args.identity and args.hid_backend == 'driverkit':
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
        if corehid:
            run(['codesign', '--verify', '--deep', '--strict', corehid])
        if driver and not args.identity:
            # Development packaging only. Ad-hoc signing does not enable DriverKit.
            run(['codesign', '--force', '--sign', '-', signed_driver])
        snapshot = ROOT / 'source-build.json'
        source = json.loads(snapshot.read_text(encoding='utf-8')) if snapshot.is_file() else {
            'revision': output(['git', '-C', ROOT, 'rev-parse', 'HEAD']),
            'dirty': bool(output(['git', '-C', ROOT, 'status', '--porcelain']))}
        manifest = {'schema_version': 1, 'bundle_id': args.bundle_id, 'architecture': args.arch,
                    'signing': 'identity' if args.identity else 'ad-hoc',
                    'hid_included': args.hid_backend != 'none', 'hid_backend': args.hid_backend,
                    'distribution': args.distribution, 'native_permissions_verified': False,
                    'hardware_codec_tested': not args.skip_hardware_tests,
                    'git_revision': source['revision'],
                    'workspace_dirty': source['dirty'],
                    'helpers': {name: hashlib.sha256((contents / 'Helpers' / name).read_bytes()).hexdigest() for name in HELPERS}}
        (contents / 'Resources/build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        run(['codesign', *signing, '--entitlements', entitlement_file, app])
        run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
        inspect_bundle(app, require_driver=args.hid_backend == 'driverkit', app_id=args.bundle_id)
        if corehid:
            from macos_distribution import signing_team
            if signing_team(app) != signing_team(app / 'Contents/Helpers/ViewflowHIDReceiver.app'):
                raise ValueError('host and CoreHID receiver signing teams differ')
        if args.distribution:
            from macos_distribution import verify_public_app
            verify_public_app(app)
        app.rename(destination)
    if getattr(args, "dmg", False):
        run([sys.executable, ROOT / "tools/package-macos-dmg.py", "--app", destination,
             "--output", destination.with_suffix(".dmg"), "--identity", args.identity,
             *(["--distribution", "--notary-profile", args.notary_profile] if args.distribution else [])])
    if args.zip:
        archive = destination.with_suffix('.zip')
        if archive.exists():
            raise ValueError(f'app built, but archive already exists: {archive}')
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', destination, archive])
    print(json.dumps({'app': str(destination), 'hid_included': args.hid_backend != 'none', 'hid_backend': args.hid_backend,
                      'signed_identity': bool(args.identity), 'permissions_verified': False}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/Viewflow.app')
    parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
    parser.add_argument('--hid-backend', choices=['corehid', 'driverkit', 'none'], default='corehid')
    parser.add_argument('--corehid-profile', type=Path)
    parser.add_argument('--corehid-bundle', type=Path, help='already signed receiver with --serve support')
    parser.add_argument('--corehid-bundle-id', default='org.viewflow.trackpad-corehid-probe')
    parser.add_argument('--distribution', action='store_true', help='require Developer ID signing and distribution profiles')
    parser.add_argument('--notary-profile', help='existing notarytool Keychain profile, used with --distribution --dmg')
    parser.add_argument('--driver-bundle', type=Path)
    parser.add_argument('--without-driver', action='store_true', help='explicit incomplete development build; cannot validate HID')
    parser.add_argument('--skip-hardware-tests', action='store_true', help='unsigned no-HID CI only: omit hardware-codec tests; never a release validation')
    parser.add_argument('--identity', help='codesign identity; public releases require Developer ID Application')
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
