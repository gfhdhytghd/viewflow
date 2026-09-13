#!/usr/bin/env python3
"""Exercise button orchestration with fake hardware/systemctl/peer discovery."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'viewflow-target.sh'
class ButtonTests(unittest.TestCase):
    def run_button(self, failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);bin=root/'bin';bin.mkdir();log=root/'calls'
            programs={
                'hdmi': '#!/bin/sh\necho "hdmi $*" >> "$CALL_LOG"\n',
                'systemctl': '''#!/bin/sh
echo "systemctl $*" >> "$CALL_LOG"
case "$*" in
 *"is-active --quiet viewflow-macos-input.service"*) exit 0 ;;
 *"is-active"*) exit 1 ;;
esac
exit 0
''',
                'python3': '''#!/bin/sh
case "$1" in
 *desktop_peer_discovery.py)
  echo discovery >> "$CALL_LOG"
  if [ "$FAIL_DISCOVERY" = 1 ]; then exit 1; fi
  echo '192.0.2.131:44149' ;;
 -)
  cat >/dev/null
  case "$2" in
   */desktop-drag/config) echo '192.0.2.83:44139' ;;
   *) echo "ready $4" >> "$CALL_LOG" ;;
  esac ;;
esac
'''}
            for name,content in programs.items():
                p=bin/name;p.write_text(content);p.chmod(0o755)
            env=os.environ | {'PATH':str(bin)+':'+os.environ['PATH'],
                'XDG_CONFIG_HOME':str(root/'config'),'XDG_STATE_HOME':str(root/'state'),
                'XDG_RUNTIME_DIR':str(root/'run'),'CALL_LOG':str(log),
                'VIEWFLOW_HDMI_HELPER':str(bin/'hdmi'),'FAIL_DISCOVERY':str(int(failure))}
            result=subprocess.run(['bash',str(SCRIPT),'set','windows'],env=env,capture_output=True,text=True)
            return result,log.read_text().splitlines(),(root/'state/hyprv/hdmi-target').read_text()

    def test_hdmi_first_then_input_service_and_same_discovered_endpoint(self):
        result,calls,target=self.run_button()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(calls[0],'hdmi send input1')
        self.assertIn('systemctl --user restart viewflow-windows-input.service',calls)
        self.assertIn('ready 192.0.2.131:44149',calls)
        self.assertNotIn('systemctl --user restart viewflow-desktop.service',calls)
        self.assertEqual(target,'windows\n')

    def test_discovery_failure_preserves_input_after_hdmi_switch(self):
        result,calls,target=self.run_button(True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(calls[0],'hdmi send input1')
        self.assertFalse(any(' stop ' in c or ' restart ' in c for c in calls))
        self.assertEqual(target,'windows\n')

if __name__=='__main__': unittest.main()
