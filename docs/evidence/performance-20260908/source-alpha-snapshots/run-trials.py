import os,subprocess,pathlib,hashlib,json
binary=pathlib.Path('target/release/vf-media-peer')
pathlib.Path('/tmp/viewflow-native-alpha-share-trial-source-sha256.json').write_text(json.dumps({'binary':hashlib.sha256(binary.read_bytes()).hexdigest(),'source':hashlib.sha256(pathlib.Path('platform/nvenc-encoder/gpu_dmabuf_encoder.cu').read_bytes()).hexdigest()},indent=2)+'\n')
for label,copy in [('4k-alpha-share-off-a1','1'),('4k-alpha-share-on-b1','0'),('4k-alpha-share-on-b2','0'),('4k-alpha-share-off-a2','1')]:
 env=os.environ.copy();env.update(VIEWFLOW_OBSERVE_FRAMES='1',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='0',VIEWFLOW_GPU_ALPHA_REUSE=('0' if copy=='1' else '1'))
 print('BEGIN',label,flush=True)
 with open('/tmp/'+label+'.log','w') as log:r=subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py',label],env=env,stdout=log,stderr=subprocess.STDOUT)
 print('END',label,'exit',r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
