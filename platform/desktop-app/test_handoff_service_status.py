import unittest
from permissions import permission_rows

class HandoffServiceStatusTests(unittest.TestCase):
    def test_missing_stopped_and_running_service(self):
        for code, state in [(1060, None), (0, 1), (5, None)]:
            row = permission_rows(dict(platform='windows', input_service_code=code, input_service_state=state), 'en')[0]
            self.assertEqual(row['tone'], 'warning')
            self.assertIn('Elevated windows', row['detail'])
            self.assertIn('unavailable', row['detail'])
        row = permission_rows(dict(platform='windows', input_service_code=0, input_service_state=4), 'en')[0]
        self.assertIn('try it automatically', row['detail'])
        self.assertNotIn('unavailable', row['detail'])

if __name__ == '__main__':
    unittest.main()
