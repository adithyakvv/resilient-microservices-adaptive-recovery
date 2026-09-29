$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e1-preflight.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}

$now=[DateTimeOffset]::Parse('2026-09-28T16:45:00+05:30')
$valid=[pscustomobject]@{
  at=$now.ToString('o');decision='CONTINUE';reason='signals within configured baseline';actionVerified=$false
  signals=[pscustomobject]@{cpu=[double]0.002;memory=[double]0.54;readiness=[double]1;httpErrors=[double]0;latency=[double]0.006;dependencyUp=$true;dependencySuccesses=-1;persistenceSamples=3;kubernetesHealthy=$true}
}
$state=@{chaosCreates=0;evaluateCalls=0;execute=$null}
$validGate=Invoke-E1PreflightGate -RequiredPersistenceSamples 3 -MaximumAgeSeconds 30 -Now $now -Evaluate {
  $state.evaluateCalls++;$state.execute=$false;$valid
} -OnPass {$state.chaosCreates++}
Assert $validGate.passed 'Fresh complete signal fixture should permit the existing E1 path.'
Assert ($state.evaluateCalls -eq 1 -and $state.chaosCreates -eq 1 -and $state.execute -eq $false) 'Valid preflight must make exactly one non-mutating evaluation, then permit injection.'

$missing=[pscustomobject]@{
  at=$now.ToString('o');decision='FAIL_SAFE';reason='required signal unavailable; Inventory CPU source kubectl.exe exit 5: Access is denied'
  signals=[pscustomobject]@{cpu='NaN';memory=[double]0.54;readiness=[double]1;httpErrors=[double]0;latency=[double]0.006;dependencyUp=$true;dependencySuccesses=-1;persistenceSamples=3;kubernetesHealthy=$false}
}
$blockedState=@{chaosCreates=0;evaluateCalls=0;execute=$null}
$blocked=Invoke-E1PreflightGate -RequiredPersistenceSamples 3 -MaximumAgeSeconds 30 -Now $now -Evaluate {
  $blockedState.evaluateCalls++;$blockedState.execute=$false;$missing
} -OnPass {$blockedState.chaosCreates++}
Assert (-not $blocked.passed) 'Missing Engine signals must block E1.'
Assert ($blocked.blockers -join ';' -match 'signals.cpu: missing or non-finite numeric value') 'Block reason must identify the exact unavailable CPU field.'
Assert (($blocked.blockers -join ';') -match 'FAIL_SAFE.*Access is denied') 'Block reason must preserve the Engine kubectl error.'
Assert ($blockedState.evaluateCalls -eq 1 -and $blockedState.chaosCreates -eq 0 -and $blockedState.execute -eq $false) 'Missing signals must block before Chaos and must not request an action.'

$unhealthy=$valid | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$unhealthy.signals.dependencyUp=$false
$unhealthyGate=Test-E1EnginePreflight -Response $unhealthy -Now $now
Assert (-not $unhealthyGate.passed -and ($unhealthyGate.blockers -join ';') -match 'signals.dependencyUp') 'Unhealthy required dependency signal must block.'

$stale=$valid | ConvertTo-Json -Depth 5 | ConvertFrom-Json
$stale.at=$now.AddMinutes(-2).ToString('o')
Assert (-not (Test-E1EnginePreflight -Response $stale -Now $now).passed) 'Stale Engine evaluation must block.'

$runner=Get-Content (Join-Path $PSScriptRoot 'run-e1-inventory-cpu.ps1') -Raw
$gateAt=$runner.IndexOf('Invoke-E1PreflightGate')
$applyAt=$runner.IndexOf("K @('apply','-f',`$manifest)")
Assert ($gateAt -ge 0 -and $applyAt -gt $gateAt) 'E1 runner must execute its Engine gate immediately before the live Chaos apply branch.'
Assert ($runner.Contains('Eval $false ''preflight''') -and -not $runner.Substring(0,$applyAt).Contains('Eval $true')) 'Preflight must be execute=false and must not issue an action before Chaos.'
$startup=Get-Content (Join-Path $PSScriptRoot 'start-demo-gui.ps1') -Raw
Assert ($startup.Contains("`$env:KUBECTL_BIN=`$kubectl") -and $startup.Contains('Get-Command kubectl')) 'Demo startup must pass the resolved kubectl path to Java.'
Assert ($startup.Contains('evaluate/adaptive-inventory-service?execute=false') -and $startup.Contains('Test-E1EnginePreflight')) 'Demo startup must verify Engine signals using a non-mutating evaluation.'
Assert ($startup.IndexOf('$env:KUBECTL_BIN=$kubectl') -lt $startup.IndexOf('Start-Process java')) 'KUBECTL_BIN must be set before launching the Engine.'
$guiServer=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'gui/server.py') -Raw
Assert ($runner.Contains('checkOnly=[bool]$CheckOnly') -and $guiServer.Contains('_is_check_only_report(report)')) 'All CheckOnly reports, including failed dry-runs, must be excluded from live E1 history in the GUI.'

'E1_PREFLIGHT_MISSING_BLOCKS_BEFORE_INJECTION=PASS'
'E1_PREFLIGHT_VALID_SIGNALS_PERMIT_EXISTING_PATH=PASS'
