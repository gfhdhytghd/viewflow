$ErrorActionPreference='Stop'
$targetProcess=Get-Process -Id 8108 -ErrorAction SilentlyContinue
if($targetProcess -and $targetProcess.StartTime.ToUniversalTime().Ticks.ToString() -eq '639243910262482721') {
 if($targetProcess.PriorityClass -eq 'Normal') { $targetProcess.PriorityClass='High'; $targetProcess.Refresh() }
 @{id=$targetProcess.Id;priority=$targetProcess.PriorityClass.ToString();start_ticks=$targetProcess.StartTime.ToUniversalTime().Ticks.ToString();time=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -Encoding UTF8 'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\esrv-priority-restored.json'
}
