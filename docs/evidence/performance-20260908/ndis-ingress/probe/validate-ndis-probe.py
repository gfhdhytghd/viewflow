from pathlib import Path
import json,struct,re,collections,sys
sys.path.insert(0,'tools');from profile_atlas_timeline import stats
rows=[json.loads(l) for l in Path('/tmp/viewflow-probe-ndis.jsonl').read_text().splitlines()];groups=collections.defaultdict(dict);fragments={}
for r in rows:
 if r['id']!=1001:continue
 b=bytes.fromhex(r['payload']['Fragment']);assert len(b)==64 and b[12:14]==b'\x08\x00' and b[23]==17 and int.from_bytes(b[36:38],'big')==49101
 assert b[26:30]==bytes([172,16,105,62]) and b[30:34]==bytes([172,16,105,70]);assert struct.unpack_from('<I',b,42)[0]==0x56465542
 batch,seq,count=struct.unpack_from('<III',b,46);k=(batch,seq);layer=int(r['payload']['LowerIfIndex']);assert r['payload']['MiniportIfIndex']=='12' and k not in groups[layer]
 assert fragments.setdefault(k,b)==b;groups[layer][k]=r['qpc']
s=Path('/tmp/viewflow-udp-burst-ndis-receiver.log').read_text();receipts={(int(b),int(n)):int(t) for b,n,t in re.findall(r'probe-packet batch=(\d+) sequence=(\d+) qpc=(\d+)',s)};freq=int(re.search(r'frequency=(\d+)',s)[1]);assert set(groups)=={12,16,17,18} and len(receipts)==420
result={'events_lost':json.loads(Path('/tmp/viewflow-probe-ndis.jsonl.summary.json').read_text())['events_lost'],'packets':420,'layer_packets':{},'layer_to_receipt_ms':{},'cross_layer_ms':{}}
assert result['events_lost']==0
for layer,g in groups.items():
 assert set(g)==set(receipts);result['layer_packets'][layer]=len(g);values=[(receipts[k]-q)*1000/freq for k,q in g.items()];assert min(values)>=0;result['layer_to_receipt_ms'][layer]=stats(values)
for a,b in zip([12,16,17],[16,17,18]):
 v=[(groups[b][k]-groups[a][k])*1000/freq for k in receipts];assert min(v)>=0;result['cross_layer_ms'][f'{a}->{b}']=stats(v)
Path('/tmp/viewflow-ndis-probe-validation.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
