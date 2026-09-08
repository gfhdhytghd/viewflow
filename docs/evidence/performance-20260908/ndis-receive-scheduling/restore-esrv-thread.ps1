$ErrorActionPreference='Stop'
$targetProcess=Get-Process -Id 8108 -ErrorAction SilentlyContinue
if($targetProcess -and $targetProcess.StartTime.ToUniversalTime().Ticks.ToString() -eq '639243910262482721') {
 $targetThread=@($targetProcess.Threads | Where-Object Id -eq 10144)
 if($targetThread.Count -eq 1 -and $targetThread[0].StartTime.ToUniversalTime().Ticks.ToString() -eq '639243910277461914' -and $targetThread[0].PriorityLevel -eq 'Normal') { $targetThread[0].PriorityLevel='TimeCritical' }
 if($targetProcess.PriorityClass -eq 'Normal') { $targetProcess.PriorityClass='High' }
 $targetProcess.Refresh(); $targetThread=@($targetProcess.Threads | Where-Object Id -eq 10144)
 @{id=$targetProcess.Id;priority=$targetProcess.PriorityClass.ToString();start_ticks=$targetProcess.StartTime.ToUniversalTime().Ticks.ToString();thread_priority=$targetThread[0].PriorityLevel.ToString();thread_base_priority=$targetThread[0].BasePriority;time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -Encoding UTF8 'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\esrv-thread-restored.json'
}
