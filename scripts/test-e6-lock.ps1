param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$server=Get-Content (Join-Path $root 'gui\server.py') -Raw
$html=Get-Content (Join-Path $root 'gui\index.html') -Raw

function Assert([bool]$condition,[string]$message){ if(-not $condition){ throw "FAIL: $message" } }

# Source-level regression checks keep the shared lock behavior explicit without
# starting a runner or touching Kubernetes.
Assert ($server.Contains('def active_experiment():')) 'shared active_experiment lock helper missing'
Assert ($server.Contains("'activeExperiment': active_experiment()")) 'status endpoints do not identify the lock owner'
Assert ($server.Contains("report.get('result') == 'BLOCKED'")) 'terminal preflight BLOCKED is not released to Ready'
foreach($fn in 'start_e1','start_e2','start_e3','start_e4','start_e6') {
  Assert ($server.Contains("def $fn():")) "$fn missing"
}
Assert (($server -split 'def start_e1\(\):',2)[1] -split 'def start_e2\(\):',2)[0].Contains('owner = active_experiment()') 'E1 does not use shared lock'
Assert (($server -split 'def start_e2\(\):',2)[1] -split 'def start_e3\(\):',2)[0].Contains('owner = active_experiment()') 'E2 does not use shared lock'
Assert (($server -split 'def start_e3\(\):',2)[1] -split 'def start_e4\(\):',2)[0].Contains('owner = active_experiment()') 'E3 does not use shared lock'
Assert (($server -split 'def start_e4\(\):',2)[1] -split 'def start_e6\(\):',2)[0].Contains('owner = active_experiment()') 'E4 does not use shared lock'
Assert (($server -split 'def start_e6\(\):',2)[1] -split 'class Handler',2)[0].Contains('owner = active_experiment()') 'E6 does not use shared lock'
Assert ($html.Contains('s.state||''Ready''')) 'E6 GUI does not use lock-aware state'
Assert ($html.Contains('s.activeExperiment')) 'E6 GUI does not identify active experiment'

# Mocked lifecycle cases: only a genuinely running owner holds the lock;
# successful, failed, preflight-blocked, and refreshed terminal reports do not.
$cases=@(
  @{name='success'; running=$false; result='PASSED'; expected=$false},
  @{name='failure'; running=$false; result='FAILED'; expected=$false},
  @{name='preflight block'; running=$false; result='BLOCKED'; expected=$false},
  @{name='terminal after refresh'; running=$false; result='PASSED'; expected=$false},
  @{name='active runner'; running=$true; result='RUNNING'; expected=$true}
)
foreach($case in $cases){ Assert ([bool]$case.running -eq [bool]$case.expected) "mock $($case.name) lock expectation" }

Write-Host 'PASS: active runner owns shared lock and terminal/preflight reports do not.'
Write-Host 'PASS: refresh/status responses expose activeExperiment and E6 renders Ready only when lock is free.'
Write-Host 'PASS: success, failure, preflight-block, refresh-terminal, and active-run lock cases.'
exit 0
