from pathlib import Path
import sys,json,hashlib,gzip
sys.path.insert(0,str(Path(__file__).resolve().parent))
import profile_atlas_timeline as t
root=Path(sys.argv[1]);packets=Path(sys.argv[2]);rows=[];hashes=[]
for mode in ['off','on']:
 p=root/('oracle-v2-'+mode+'.log');txt=p.read_text() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes()).decode()
 diag=root/('oracle-v2-'+mode+'-diagnostics.log')
 txt+='\n'+(diag.read_text() if diag.exists() else gzip.decompress(Path(str(diag)+'.gz').read_bytes()).decode())
 data=[t.numbers(r) for r in t.rows(txt,'cache-oracle ')];cache=[t.numbers(r) for r in t.rows(txt,'GPU import-cache ')];final=t.numbers(t.rows(txt,'cache-oracle-result ')[0])
 assert len(data)==len(cache)==64 and final['frames']==final['color_frames_checked']==64
 assert final['alpha_bytes_checked']==64*3840*2400 and len({r['fd'] for r in data})==1
 assert len({(r['dev'],r['ino']) for r in data})==5
 assert all(r['frame']==i+1 and r['correct']==1 for i,r in enumerate(data))
 assert all(r['entries']<=4 and r['capacity']==4 and r['enabled']==int(mode=='on') for r in cache)
 if mode=='on':assert cache[-1]['hits']>0 and cache[-1]['evictions']>0 and cache[-1]['entries']==4
 else:assert cache[-1]['hits']==cache[-1]['misses']==cache[-1]['entries']==0
 p=packets/('oracle-v2-'+mode+'.h264');blob=p.read_bytes() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes());h=hashlib.sha256(blob).hexdigest();hashes.append(h)
 rows.append(dict(mode=mode,summary=final,cache_last=cache[-1],frames=data,packet_sha256=h,packet_bytes=len(blob)))
assert hashes[0]==hashes[1]
result=dict(packet_streams_identical=True,runs=rows)
(root/'oracle-comparison.json').write_text(json.dumps(result,indent=2)+'\n');print('two 64-frame oracles: same FD / 5 storage keys, hits and LRU evictions, 589824000 exact alpha bytes each; identical H264 streams',hashes[0])
