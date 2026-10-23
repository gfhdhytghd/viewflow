from pathlib import Path
import json,sys
rows=json.loads(Path(sys.argv[1]).read_text())
for r in rows:
 b=r['bounds']['unique_capture_stage_samples']['capture_to_desktop_upper_ms']
 bg=r['background_snapshots']
 last=bg[-1] if bg else {}
 phase=r['stages']['wall_stage_ms']['commit to desktop (queue + GPU + DWM; NOT DWM CPU)']
 print(r['label'], 'native',round(r['native_commit_hz'],2),'desktop/30s',round(r['desktop']['changes_per_requested_second'],2),'capture-ms',round(b['median'],2),round(b['p95'],2),'postcommit-ms',round(phase['median'],2),'background',last)
