using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using System.Text.Json;
using var log=TraceLog.OpenOrConvert(args[0]);
var counts=new Dictionary<string,int>();
using var output=new StreamWriter(args[1]);
foreach(TraceEvent e in log.Events) {
 var key=e.ProviderName+"/"+e.EventName; counts[key]=counts.GetValueOrDefault(key)+1;
 if(!e.ProviderName.Contains("NDIS",StringComparison.OrdinalIgnoreCase))continue;
 var payload=new Dictionary<string,object>();
 foreach(var name in e.PayloadNames) {var value=e.PayloadByName(name);payload[name]=value is byte[] b ? Convert.ToHexString(b) : value?.ToString()??"";}
 output.WriteLine(JsonSerializer.Serialize(new {qpc=e.TimeStampQPC,time_ms=e.TimeStampRelativeMSec,pid=e.ProcessID,tid=e.ThreadID,provider=e.ProviderName,name=e.EventName,id=e.ID,payload,raw=Convert.ToHexString(e.EventData())}));
}
File.WriteAllText(args[1]+".summary.json",JsonSerializer.Serialize(new {events_lost=log.EventsLost,counts}));
Console.WriteLine(JsonSerializer.Serialize(new {events_lost=log.EventsLost,counts}));
