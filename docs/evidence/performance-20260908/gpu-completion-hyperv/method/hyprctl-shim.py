#!/usr/bin/python3
# Namespace isolation only. Scheduling is selected by the actual source config.
import os,sys
args=[arg.replace('hl.plugin.viewflow_capture.','hl.plugin.viewflow_capture_modes_test.') for arg in sys.argv[1:]]
os.execv('/usr/bin/hyprctl',['hyprctl',*args])
