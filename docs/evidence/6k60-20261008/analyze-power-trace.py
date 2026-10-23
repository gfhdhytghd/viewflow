"""Summarize decoded ETW coverage and retain non-timer/runtime-PM events."""
import collections,gzip,json,sys,xml.etree.ElementTree as E
ns={'e':'http://schemas.microsoft.com/win/2004/08/events/event'}
p=sys.argv[1]; counts=collections.Counter(); first=last=None;header=None;selected=[]
with (gzip.open(p,'rb') if p.endswith('.gz') else open(p,'rb')) as f:
 for _,e in E.iterparse(f,events=['end']):
  if e.tag!='{'+ns['e']+'}Event':continue
  field=lambda path:e.findtext(path,namespaces=ns)
  event_id=field('e:System/e:EventID'); counts[event_id]+=1
  t=e.find('e:System/e:TimeCreated',ns).get('SystemTime')
  data={x.get('Name'):(x.text or '').strip() for x in e.findall('e:EventData/e:Data',ns)}
  if event_id=='0' and 'EventsLost' in data:header=data
  else:
   first=min(first,t) if first else t;last=max(last,t) if last else t
   if event_id not in {'557','63','307','309','312','313','314','317','330','331','333'}:
    selected.append({'time':t,'id':event_id,'task':field('e:RenderingInfo/e:Task'),'execution':e.find('e:System/e:Execution',ns).attrib,'data':data})
  e.clear()
print(json.dumps({'header':header,'first_event':first,'last_event':last,'counts':counts,'events':sorted(selected,key=lambda x:x['time'])},ensure_ascii=False,indent=2))
