import os,subprocess,pathlib,hashlib,json
paths=['target/release/vf-media-peer','crates/viewflowd/src/atlas_udp_pacing.rs','crates/viewflowd/src/atlas_socket_trace.rs','crates/viewflowd/src/lib.rs']
pathlib.Path('/tmp/viewflow-udp-pacing-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
for label,packets in [('4k-pacing-off-a1','0'),('4k-pacing-eight-b1','8'),('4k-pacing-eight-b2','8'),('4k-pacing-off-a2','0')]:
 env=os.environ.copy();env.update(VIEWFLOW_OBSERVE_FRAMES='0',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1',VIEWFLOW_GPU_ALPHA_REUSE='1',VIEWFLOW_GPU_ALPHA_DIFF='1',VIEWFLOW_QUIC_BURST_PACKETS=packets)
 print('BEGIN',label,flush=True)
 with open('/tmp/'+label+'.log','w') as log:r=subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py',label],env=env,stdout=log,stderr=subprocess.STDOUT)
 print('END',label,'exit',r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
