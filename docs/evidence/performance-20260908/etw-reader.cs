using Microsoft.Diagnostics.Tracing;
using Microsoft.Diagnostics.Tracing.Etlx;
using Microsoft.Diagnostics.Tracing.Parsers.Kernel;
using Microsoft.Diagnostics.Symbols;
using var log = TraceLog.OpenOrConvert(args[0]);
File.WriteAllText(args[1]+".processes.json",System.Text.Json.JsonSerializer.Serialize(log.Processes.Select(p=>new {pid=p.ProcessID,name=p.Name,start_ms=p.StartTimeRelativeMsec,end_ms=p.EndTimeRelativeMsec}).ToArray()));
if(args.Length>2 && args[2]=="metadata") {
 using var output=new StreamWriter(args[1]);
 foreach(TraceEvent e in log.Events) {
  if(e.TimeStampRelativeMSec>10000) break;
  if(e.ProviderName.Contains("Dxg") && (e.EventName.StartsWith("NodeMetadata") || e.EventName.StartsWith("Adapter"))) output.WriteLine(e.ToString());
 }
 return;
}
var processes = log.Processes.Where(p=>p.Name=="viewflow_windows_composition_preview" || p.Name=="vf-media-peer").ToArray();
foreach(var p in processes) Console.WriteLine($"process={p.Name} pid={p.ProcessID} start={p.StartTimeRelativeMsec} end={p.EndTimeRelativeMsec}");
var ids=processes.Select(p=>p.ProcessID).ToHashSet();
var active=processes.Where(p=>p.Name=="viewflow_windows_composition_preview").OrderBy(p=>p.StartTimeRelativeMsec).Last();
var low=active.StartTimeRelativeMsec;var high=active.EndTimeRelativeMsec;
Console.WriteLine($"events_lost={log.EventsLost} active_low_ms={low} active_high_ms={high}");
var samples = new List<(int ProcessID, TraceCallStack Stack)>();
var eventCounts = new Dictionary<string,int>(); var examples=new Dictionary<string,string>();
using var gpuEvents=new StreamWriter(args[1]+".gpu.jsonl");
foreach(TraceEvent e in log.Events) {
 if(e.TimeStampRelativeMSec<low || e.TimeStampRelativeMSec>high) continue;
 if(e is SampledProfileTraceData && ids.Contains(e.ProcessID)) samples.Add((e.ProcessID,e.CallStack()));
 if(e.ProviderName.Contains("Dxg") || e.ProviderName.Contains("Dwm") || e.ProviderName.Contains("DirectComposition")) {
  var payload=new Dictionary<string,string>(); foreach(var name in e.PayloadNames) {try {var value=e.PayloadByName(name);payload[name]=value is Array arr ? System.Text.Json.JsonSerializer.Serialize(arr.Cast<object>().Select(x=>x?.ToString()).ToArray()) : value?.ToString()??"";} catch {payload[name]="unavailable";}}
  gpuEvents.WriteLine(System.Text.Json.JsonSerializer.Serialize(new {qpc=e.TimeStampQPC,time_ms=e.TimeStampRelativeMSec,pid=e.ProcessID,tid=e.ThreadID,provider=e.ProviderName,name=e.EventName,id=e.ID,payload}));
  var key=e.ProviderName+"/"+e.EventName;eventCounts[key]=eventCounts.GetValueOrDefault(key)+1;
  if(!examples.ContainsKey(key)) examples[key]=e.ToString();
 }
}
File.WriteAllText(args[1]+".events.json",System.Text.Json.JsonSerializer.Serialize(eventCounts));
File.WriteAllLines(args[1]+".examples.txt",examples.Select(e=>e.Key+"\n"+e.Value));

var modules = new HashSet<TraceModuleFile>();
foreach(var s in samples) for(var f=s.Stack;f!=null;f=f.Caller) if(f.CodeAddress.ModuleFile!=null) modules.Add(f.CodeAddress.ModuleFile);
using(var symbols = new SymbolReader(Console.Out, Path.Combine(Environment.CurrentDirectory,"target","release")+";"+Path.Combine(Environment.CurrentDirectory,"native-build","Release")+";srv*C:\\Users\\wilf\\Viewflow\\symbols*https://msdl.microsoft.com/download/symbols")) {
 foreach(var m in modules) {try {log.CodeAddresses.LookupSymbolsForModule(symbols,m);} catch(Exception e) {Console.WriteLine("symbol-error="+e.Message);}}
}
var counts=new Dictionary<string,int>();int missing=0;
foreach(var s in samples){var frames=new List<string>();for(var f=s.Stack;f!=null;f=f.Caller){var a=f.CodeAddress;var module=a.ModuleFile?.Name??"unknown";var name=a.FullMethodName;if(string.IsNullOrEmpty(name))name=module+"!0x"+a.Address.ToString("x");frames.Add(name.Replace(';',':').Replace('\n',' '));}if(frames.Count==0){missing++;frames.Add("[missing stack]");}frames.Reverse();frames.Insert(0,processes.First(p=>p.ProcessID==s.ProcessID).Name);var key=string.Join(';',frames);counts[key]=counts.GetValueOrDefault(key)+1;}
File.WriteAllLines(args[1],counts.Select(k=>$"{k.Key} {k.Value}"));Console.WriteLine($"samples={samples.Count} missing={missing} stacks={counts.Count}");
