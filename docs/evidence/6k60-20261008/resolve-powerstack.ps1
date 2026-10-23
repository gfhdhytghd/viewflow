$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$env:_NT_SYMBOL_PATH='srv*C:\Users\wilf\Viewflow\symbols*https://msdl.microsoft.com/download/symbols'
@('base 10000000','load C:\Windows\System32\win32kfull.sys','addr 1029c89a','addr 10048693','addr 100483fe','addr 101db803','addr 1002a44c','addr 1002a39f','addr 10029ea8','addr 10261680','q') | & 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\dbh.exe'
