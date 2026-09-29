$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$h=Get-Content (Join-Path $root 'gui\index.html') -Raw
function Assert([bool]$ok,[string]$m){if(-not$ok){throw "FAIL: $m"}}

foreach($e in 'e3','e4','e6'){
  Assert ($h.Contains(('data-experiment="' + $e + '"'))) "$e report disclosure missing"
  Assert ($h.Contains(('id="' + $e + '-report"'))) "$e report host missing"
}
$order=@('Timestamps and durations (IST)','Measurements / probes','Pods and health','Engine evaluations','Chaos and cleanup')
$e3=$h.Substring($h.IndexOf('function e3Report'),$h.IndexOf('function e3ProbeDetails')-$h.IndexOf('function e3Report'))
$e4=$h.Substring($h.IndexOf('function e4Report'),$h.IndexOf('let e4PollTimer')-$h.IndexOf('function e4Report'))
$e6=$h.Substring($h.IndexOf('function e6Report'),$h.IndexOf('let e6PollTimer')-$h.IndexOf('function e6Report'))
foreach($chunkName in @{'E3'=$e3;'E4'=$e4;'E6'=$e6}.Keys){$chunk=@{'E3'=$e3;'E4'=$e4;'E6'=$e6}[$chunkName];$last=-1;foreach($label in $order){$pos=$chunk.IndexOf($label);Assert ($pos -gt $last) "$chunkName section order missing/out of order: $label";$last=$pos}}
Assert ($h.Contains('outer.open=!!s.running')) 'running/terminal disclosure state is not explicit'
Assert ($h.Contains("outer.querySelectorAll('details').forEach(d=>d.open=!!s.running)")) 'nested disclosure state is not synchronized'
Assert ($h.Contains('function e3ProbeDetails')) 'E3 probe rendering hook missing'
Write-Output 'E3_E4_E6_LAYOUT_TESTS=PASS'
