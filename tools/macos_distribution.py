"""Checks for the public CoreHID release, separate from development signing."""
import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

HID_CAPABILITY = 'com.apple.developer.hid.virtual.device'


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def validate_distribution_profile(profile, bundle_id):
    entitlements = profile.get('Entitlements', {})
    team = entitlements.get('com.apple.developer.team-identifier')
    identifier = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier'))
    if not team or identifier != f'{team}.{bundle_id}':
        raise ValueError('distribution profile must explicitly cover this bundle ID and team')
    if entitlements.get(HID_CAPABILITY) is not True:
        raise ValueError('distribution profile lacks HID Virtual Device')
    if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices') is not True:
        raise ValueError('public release requires an all-devices Developer ID profile, not a registered-device profile')
    if any(entitlements.get(key) for key in ('get-task-allow', 'com.apple.security.get-task-allow')):
        raise ValueError('public release profile must not allow debugging')
    expiry = profile.get('ExpirationDate')
    if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('distribution profile is expired')
    return team


def signature(path):
    return run(['codesign', '-dv', '--verbose=4', path], stderr=subprocess.PIPE, text=True).stderr


def signing_team(path):
    for line in signature(path).splitlines():
        if line.startswith('TeamIdentifier=') and line != 'TeamIdentifier=not set':
            return line.split('=', 1)[1]
    raise ValueError(f'missing signing team: {path}')


def verify_developer_id(path):
    run(['codesign', '--verify', '--strict', path])
    details = signature(path)
    if not any(line.startswith('Authority=Developer ID Application:') for line in details.splitlines()):
        raise ValueError(f'not signed with Developer ID Application: {path}')
    if 'runtime' not in details or not any(line.startswith('Timestamp=') for line in details.splitlines()):
        raise ValueError(f'Hardened Runtime and secure timestamp required: {path}')
    data = run(['codesign', '-d', '--entitlements', ':-', path], stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
    entitlements = plistlib.loads(data) if data.strip() else {}
    if entitlements.get('com.apple.security.get-task-allow') or entitlements.get('get-task-allow'):
        raise ValueError(f'debugging entitlement in public executable: {path}')
    return entitlements


def verify_profile_certificate(profile, app):
    with tempfile.TemporaryDirectory(prefix='viewflow-certificate-') as temporary:
        prefix = Path(temporary) / 'certificate'
        run(['codesign', '-d', '--extract-certificates', prefix, app], stderr=subprocess.PIPE)
        certificate = prefix.with_name(prefix.name + '0').read_bytes()
        if certificate not in profile.get('DeveloperCertificates', []):
            raise ValueError('CoreHID signing certificate is not included in its provisioning profile')


def verify_public_app(app):
    app = Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('ViewflowHIDBackend') != 'corehid':
        raise ValueError('public package must explicitly select CoreHID')
    if (app / 'Contents/Library/SystemExtensions').exists():
        raise ValueError('public CoreHID package contains a legacy driver')
    run(['codesign', '--verify', '--deep', '--strict', app])
    host_entitlements = verify_developer_id(app)
    if any(key.startswith('com.apple.developer.driverkit') or key == 'com.apple.developer.system-extension.install'
           for key in host_entitlements):
        raise ValueError('CoreHID host still claims DriverKit/system-extension entitlements')
    receiver = app / 'Contents/Helpers/ViewflowHIDReceiver.app'
    receiver_info = plistlib.loads((receiver / 'Contents/Info.plist').read_bytes())
    if receiver_info.get('ViewflowHIDServiceVersion') != 1:
        raise ValueError('CoreHID receiver does not support the shared service')
    profile = plistlib.loads(run(['security', 'cms', '-D', '-i', receiver / 'Contents/embedded.provisionprofile'],
                                stdout=subprocess.PIPE).stdout)
    team = validate_distribution_profile(profile, receiver_info['CFBundleIdentifier'])
    signed = verify_developer_id(receiver)
    verify_profile_certificate(profile, receiver)
    if signed.get(HID_CAPABILITY) is not True or signing_team(app) != team or signing_team(receiver) != team:
        raise ValueError('CoreHID signed entitlement or host/receiver team mismatch')
    identifier = profile['Entitlements'].get('com.apple.application-identifier', profile['Entitlements'].get('application-identifier'))
    if signed.get('com.apple.application-identifier') != identifier:
        raise ValueError('CoreHID signed application identifier does not match its profile')
    for helper in (app / 'Contents/Helpers').iterdir():
        if helper.is_file():
            verify_developer_id(helper)
            if signing_team(helper) != team:
                raise ValueError(f'helper signing team mismatch: {helper.name}')
    return {'backend': 'corehid', 'team': team, 'profile': 'Developer ID', 'notarization_checked': False}


def notarize(path, keychain_profile):
    """Credentials remain in Keychain; use a preconfigured notarytool profile."""
    result = run(['xcrun', 'notarytool', 'submit', path, '--keychain-profile', keychain_profile,
                  '--wait', '--output-format', 'json'], stdout=subprocess.PIPE, text=True)
    report = json.loads(result.stdout)
    Path(str(path) + '.notary.json').write_text(json.dumps(report, indent=2) + '\n')
    if report.get('status') != 'Accepted':
        if report.get('id'):
            run(['xcrun', 'notarytool', 'log', report['id'], '--keychain-profile', keychain_profile,
                 str(path) + '.notary-log.json'])
        raise ValueError(f"notarization not accepted: {report.get('status')} ({report.get('id')})")
    return report
