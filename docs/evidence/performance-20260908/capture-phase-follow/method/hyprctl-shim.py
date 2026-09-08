#!/usr/bin/python3
import os,sys
args=sys.argv[1:]
for i,arg in enumerate(args):
 if 'hl.plugin.viewflow_capture.' in arg:
  arg=arg.replace('hl.plugin.viewflow_capture.window_stream_start(', 'hl.plugin.viewflow_capture_phase_test.'+('window_stream_start_commit(' if os.environ.get('VIEWFLOW_COMMIT_MODE')=='commit' else 'window_stream_start('))
  arg=arg.replace('hl.plugin.viewflow_capture.window_stream_stop(', 'hl.plugin.viewflow_capture_phase_test.window_stream_stop(')
  args[i]=arg
os.execv('/usr/bin/hyprctl',['hyprctl',*args])
