import datetime
import importlib.util
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from macos_distribution import HID_CAPABILITY, validate_distribution_profile, verify_profile_certificate

spec = importlib.util.spec_from_file_location('mac_package', ROOT / 'tools/build-macos-app.py')
mac = importlib.util.module_from_spec(spec); spec.loader.exec_module(mac)


class DistributionTests(unittest.TestCase):
    def profile(self):
        return {'ProvisionsAllDevices': True,
                'ExpirationDate': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=10),
                'Entitlements': {'com.apple.developer.team-identifier': 'TEAM',
                                 'com.apple.application-identifier': 'TEAM.org.viewflow.hid', HID_CAPABILITY: True}}

    def test_distribution_and_development_are_not_interchangeable(self):
        profile = self.profile()
        self.assertEqual(validate_distribution_profile(profile, 'org.viewflow.hid'), 'TEAM')
        profile['ProvisionedDevices'] = ['development-mac']
        with self.assertRaisesRegex(ValueError, 'registered-device'): validate_distribution_profile(profile, 'org.viewflow.hid')
        del profile['ProvisionedDevices']; profile['Entitlements']['get-task-allow'] = True
        with self.assertRaisesRegex(ValueError, 'debugging'): validate_distribution_profile(profile, 'org.viewflow.hid')

    def test_approval_without_correct_app_profile_is_insufficient(self):
        profile = self.profile()
        with self.assertRaisesRegex(ValueError, 'bundle ID'): validate_distribution_profile(profile, 'org.viewflow.other')
        del profile['Entitlements'][HID_CAPABILITY]
        with self.assertRaisesRegex(ValueError, 'HID Virtual Device'): validate_distribution_profile(profile, 'org.viewflow.hid')

    def test_actual_signer_must_be_authorized_by_profile(self):
        def extract(args, **kwargs):
            Path(str(args[3]) + '0').write_bytes(b'actual signing certificate')
        with patch('macos_distribution.run', side_effect=extract):
            verify_profile_certificate({'DeveloperCertificates': [b'actual signing certificate']}, Path('receiver.app'))
            with self.assertRaisesRegex(ValueError, 'signing certificate'):
                verify_profile_certificate({'DeveloperCertificates': [b'other certificate from same team']}, Path('receiver.app'))

    def test_expired_and_non_distribution_profiles_are_rejected(self):
        profile = self.profile()
        profile['ExpirationDate'] = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
        with self.assertRaisesRegex(ValueError, 'expired'): validate_distribution_profile(profile, 'org.viewflow.hid')
        profile = self.profile(); del profile['ProvisionsAllDevices']
        with self.assertRaisesRegex(ValueError, 'all-devices'): validate_distribution_profile(profile, 'org.viewflow.hid')

    def test_hardware_tests_cannot_be_skipped_for_signed_or_public_packages(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(mac.sys, 'platform', 'darwin'):
            for without_driver, identity, distribution in [(False, None, False), (True, 'Developer ID', False), (True, None, True)]:
                args = SimpleNamespace(output=Path(temp) / 'Viewflow.app', without_driver=without_driver,
                    hid_backend='corehid', skip_hardware_tests=True, identity=identity, distribution=distribution)
                with self.assertRaisesRegex(ValueError, 'release builds require every test'):
                    mac.package(args)

    def test_corehid_bundle_requires_provisioned_shared_receiver_and_no_dext(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); helpers = root / 'helpers'; helpers.mkdir()
            binary = root / 'Viewflow'; binary.write_bytes(b'mock'); binary.chmod(0o755)
            for name in mac.HELPERS:
                (helpers / name).write_bytes(b'mock'); (helpers / name).chmod(0o755)
            nested = root / 'ViewflowHIDReceiver.app'; contents = nested / 'Contents'; (contents / 'MacOS').mkdir(parents=True)
            info = {'CFBundleExecutable': 'ViewflowHIDReceiver', 'ViewflowHIDServiceVersion': 1}
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
            (contents / 'embedded.provisionprofile').write_bytes(b'mock')
            receiver = contents / 'MacOS/ViewflowHIDReceiver'; receiver.write_bytes(b'mock'); receiver.chmod(0o755)
            app = root / 'Viewflow.app'
            mac.copy_payload(app, binary, helpers, None, corehid=nested, hid_backend='corehid')
            self.assertEqual(len(mac.inspect_bundle(app)), 2 + len(mac.HELPERS))
            self.assertEqual(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['LSMinimumSystemVersion'], '26.0')
            installed = app / 'Contents/Helpers/ViewflowHIDReceiver.app/Contents'
            info['ViewflowHIDServiceVersion'] = 0; (installed / 'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, 'shared service'): mac.inspect_bundle(app)
            info['ViewflowHIDServiceVersion'] = 1; (installed / 'Info.plist').write_bytes(plistlib.dumps(info))
            (app / 'Contents/Library/SystemExtensions').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'legacy system'): mac.inspect_bundle(app)


if __name__ == '__main__': unittest.main()
