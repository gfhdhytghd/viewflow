import datetime
import unittest
from build import CAPABILITY, profile_entitlements


class ProfileTests(unittest.TestCase):
    def profile(self):
        return {'ExpirationDate': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1),
                'Entitlements': {CAPABILITY: True, 'com.apple.developer.team-identifier': 'TEAM',
                                 'com.apple.application-identifier': 'TEAM.org.viewflow.hid-receiver'}}

    def test_granted_profile(self):
        self.assertIs(profile_entitlements(self.profile(), 'org.viewflow.hid-receiver')[CAPABILITY], True)

    def test_old_profile_is_not_account_approval(self):
        profile = self.profile()
        del profile['Entitlements'][CAPABILITY]
        with self.assertRaisesRegex(ValueError, 'regenerate'):
            profile_entitlements(profile, 'org.viewflow.hid-receiver')

    def test_wrong_app_and_expiry(self):
        with self.assertRaisesRegex(ValueError, 'bundle ID'):
            profile_entitlements(self.profile(), 'org.viewflow.app')
        profile = self.profile()
        profile['ExpirationDate'] -= datetime.timedelta(days=2)
        with self.assertRaisesRegex(ValueError, 'expired'):
            profile_entitlements(profile, 'org.viewflow.hid-receiver')


if __name__ == '__main__':
    unittest.main()
