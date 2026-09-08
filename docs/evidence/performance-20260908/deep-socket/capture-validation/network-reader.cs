using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using System.Text.Json;
using var log=TraceLog.OpenOrConvert(args[0]);
var counts=new Dictionary<string,int>();
using var output=new StreamWriter(args[1]);
foreach(TraceEvent e in log.Events) {
 var key=e.ProviderName+"/"+e.EventName;
 counts[key]=counts.GetValueOrDefault(key)+1;
 if(!e.EventName.StartsWith("UdpIp"))continue;
 var payload=new Dictionary<string,string>();
 foreach(var name in e.PayloadNames)payload[name]=e.PayloadByName(name)?.ToString()??"";
 if(!payload.Any(p=>(p.Key=="sport"||p.Key=="dport") && p.Value==args[2]))continue;
 output.WriteLine(JsonSerializer.Serialize(new {qpc=e.TimeStampQPC,time_ms=e.TimeStampRelativeMSec,pid=e.ProcessID,tid=e.ThreadID,provider=e.ProviderName,name=e.EventName,id=e.ID,payload}));
}
File.WriteAllText(args[1]+".summary.json",JsonSerializer.Serialize(new {events_lost=log.EventsLost,counts}));
Console.WriteLine(JsonSerializer.Serialize(new {events_lost=log.EventsLost,counts}));
