using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using Microsoft.Diagnostics.Symbols;
using System.Text.Json;
using var log=TraceLog.OpenOrConvert(args[0]);
var counts=new Dictionary<string,int>();
var deliveries=new List<(string Event,TraceCallStack Stack)>();
var processes=log.Processes.Where(p=>p.Name=="vf-media-peer").ToArray();
var pids=processes.Select(p=>p.ProcessID).ToHashSet();
Console.WriteLine("receiver_pids="+string.Join(",",pids));
using var output=new StreamWriter(args[1]);
int selected=0,missing=0;
foreach(TraceEvent e in log.Events) {
 var key=e.ProviderName+"/"+e.EventName+"/"+e.ID;
 counts[key]=counts.GetValueOrDefault(key)+1;
 bool delivery=e.ProviderName=="Microsoft-Windows-TCPIP" && (int)e.ID==1170;
 bool udp=e.EventName.StartsWith("UdpIp");
 if(!delivery && !udp)continue;
 var payload=new Dictionary<string,string>();
 foreach(var name in e.PayloadNames){var v=e.PayloadByName(name);payload[name]=v is byte[] b ? Convert.ToHexString(b):v?.ToString()??"";}
 if(udp && !payload.Any(p=>(p.Key=="sport"||p.Key=="dport")&&p.Value==args[2]))continue;
 if(delivery && !(payload.TryGetValue("Pid",out var process) && int.TryParse(process,out int pid) && pids.Contains(pid)))continue;
 var evt=JsonSerializer.Serialize(new {qpc=e.TimeStampQPC,time_ms=e.TimeStampRelativeMSec,pid=e.ProcessID,tid=e.ThreadID,provider=e.ProviderName,name=e.EventName,id=e.ID,payload});
 if(delivery){deliveries.Add((evt,e.CallStack()));selected++;if(e.CallStack()==null)missing++;}
 else output.WriteLine(evt);
}
var modules=new HashSet<TraceModuleFile>();
foreach(var d in deliveries)for(var f=d.Stack;f!=null;f=f.Caller)if(f.CodeAddress.ModuleFile!=null)modules.Add(f.CodeAddress.ModuleFile);
using(var symbols=new SymbolReader(Console.Out,"srv*C:\\Users\\wilf\\Viewflow\\symbols*https://msdl.microsoft.com/download/symbols")){
 foreach(var m in modules){try{Console.WriteLine("symbol-module="+m.Name);log.CodeAddresses.LookupSymbolsForModule(symbols,m);}catch(Exception e){Console.WriteLine("symbol-error="+e.Message);}}
}
foreach(var d in deliveries){var stack=new List<object>();for(var f=d.Stack;f!=null;f=f.Caller){var a=f.CodeAddress;stack.Add(new {module=a.ModuleFile?.Name,address=a.Address.ToString("x"),name=a.FullMethodName});}
 output.WriteLine(JsonSerializer.Serialize(new {delivery=JsonSerializer.Deserialize<JsonElement>(d.Event),stack}));}
File.WriteAllText(args[1]+".summary.json",JsonSerializer.Serialize(new {events_lost=log.EventsLost,selected,missing,processes=processes.Select(p=>new {pid=p.ProcessID,start_ms=p.StartTimeRelativeMsec,end_ms=p.EndTimeRelativeMsec}),counts}));
Console.WriteLine(JsonSerializer.Serialize(new {events_lost=log.EventsLost,selected,missing,modules=modules.Select(m=>m.Name)}));
