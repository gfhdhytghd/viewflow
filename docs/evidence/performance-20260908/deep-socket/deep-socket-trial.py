import os,subprocess
from pathlib import Path
env=os.environ.copy();env.update(VIEWFLOW_OBSERVE_FRAMES='0',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1')
subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py','4k-deep-socket'],env=env,check=True)
