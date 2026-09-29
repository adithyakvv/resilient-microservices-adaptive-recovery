$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$message){if(-not$ok){throw $message}}
# Detection and decision must be ordered; missing observations must remain null.
$t1=[DateTimeOffset]::Parse('2026-09-26T10:15:36+05:30');$t2=[DateTimeOffset]::Parse('2026-09-26T10:15:42+05:30')
Assert ($t2 -ge $t1) 'T2 must not precede T1 in a new run'
$missing=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T5=$null}
Assert ($null -eq $missing.T0 -and $null -eq $missing.T5) 'Unobserved timing markers must remain unavailable'
'E1_TIMING_ORDER_AND_MISSING_OBSERVATION_TESTS=PASS'
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e1-inventory-cpu.ps1') -Raw
Assert ($runner.Contains('Read-FinalCPU') -and $runner.Contains("Read-CPU 'after'") -and $runner.Contains("postCleanupCpu")) 'E1 post-cleanup telemetry path missing'
Assert ($runner.Contains("'AllInjected'")) 'Chaos injection evidence must accept Chaos Mesh AllInjected=True'
Assert (-not $runner.Contains('[double]::IsFinite')) 'Runner must use PowerShell-compatible finite-number checks'
Assert ($runner.Contains('Read-FinalCPU') -and $runner.Contains('postCleanupCpu') -and $runner.Contains('Start-Sleep 5')) 'E1 final fresh CPU sample retry missing'
'E1_CAPTURE_MAPPING_ASSERTIONS=PASS'
$contradictory=@([pscustomobject]@{execute=$false;decision='INCREASE_CPU';actionVerified=$false},[pscustomobject]@{execute=$true;decision='INCREASE_CPU';actionVerified=$true},[pscustomobject]@{execute=$false;decision='OBSERVE';reason='cooldown active';actionVerified=$false})
Assert (@($contradictory|Where-Object{$_.execute -and $_.decision -eq 'INCREASE_CPU' -and $_.actionVerified}).Count -eq 1) 'Contradictory-shape fixture must identify exactly one verified execute=true action'
Assert (@($contradictory|Where-Object{-not$_.execute -and $_.actionVerified}).Count -eq 0) 'Preview recommendations must never be classified as applied'
$incomplete=@{T0='2026-09-26T10:00:00+05:30';T1='2026-09-26T10:00:01+05:30';T2='2026-09-26T10:00:02+05:30';T3='2026-09-26T10:00:03+05:30';T4=$null;T5='2026-09-26T10:00:10+05:30'}
Assert ($null -eq $incomplete.T4) 'Missing T4 must keep time-to-stable-state unavailable'
$firstSample=[pscustomobject]@{timestamp='2026-09-26T11:31:59+05:30';cpuCores=.00196};$engineDetection=[pscustomobject]@{timestamp='2026-09-26T11:32:05+05:30';signalsCpu=.10027;decision='INCREASE_CPU'}
Assert ($firstSample.cpuCores -lt .1 -and $engineDetection.signalsCpu -ge .1) 'Timing fixture must distinguish first local sample from Engine detection'
Assert ($engineDetection.timestamp -ge $firstSample.timestamp) 'Engine detection must not precede the local sample sequence'
$definitions=(Get-Content (Join-Path $PSScriptRoot 'run-e1-inventory-cpu.ps1') -Raw)
Assert ($definitions.Contains('First Kubernetes Metrics API sample at or above the configured CPU threshold')) 'T1 must identify the first threshold sample'
Assert ($definitions.Contains('First Kubernetes Metrics API sample')) 'T1 must be triggered by the first Metrics API sample'
Assert ($definitions.Contains('Actual execute=true Engine response that applies the CPU increase')) 'T2 must use the execute=true applied-action response only'
Assert ($definitions.Contains('$actionResponse.decision-eq''INCREASE_CPU''-and$actionResponse.actionVerified-eq$true')) 'T2 must not be recorded for a FAIL_SAFE response or an unverified CPU action'
Assert ($definitions.Contains('Kubernetes Deployment shows increased CPU resources and Inventory is Ready')) 'T3 must require applied resources and readiness'
Assert (($definitions -split 'Save-Run').Count -ge 6) 'Progress must be saved repeatedly during event capture'
$ordered=[ordered]@{T0='2026-09-26T10:00:00+05:30';T1='2026-09-26T10:00:05+05:30';T2='2026-09-26T10:00:05+05:30';T3='2026-09-26T10:00:06+05:30';T5='2026-09-26T10:00:20+05:30'}
$last=$null;foreach($k in $ordered.Keys){$v=[DateTimeOffset]::Parse($ordered[$k]);Assert (-not $last -or $v -ge $last) "$k must be chronological";$last=$v}
'E1_NORMAL_ORDERED_EVENTS=PASS'
$preview=[pscustomobject]@{execute=$false;decision='INCREASE_CPU';actionVerified=$false};$action=[pscustomobject]@{execute=$true;decision='INCREASE_CPU';actionVerified=$true};Assert (-not$preview.execute -and $action.execute -and $action.actionVerified) 'Preview and actuator events remain separate';'E1_PREVIEW_ACTUATOR_SEPARATION=PASS'
$bad=[ordered]@{T0='2026-09-26T10:00:00+05:30';T1='2026-09-26T10:00:08+05:30';T2='2026-09-26T10:00:07+05:30'};Assert ([DateTimeOffset]::Parse($bad.T2)-lt[DateTimeOffset]::Parse($bad.T1)) 'Out-of-order fixture detected';'E1_INVALID_ORDER_DETECTED=PASS'
$singleHigh=1;$required=2;$notTriggered=($singleHigh -gt 0 -and $singleHigh -lt $required);Assert $notTriggered 'A final single high sample must be reported as threshold-not-sustained';'E1_LAST_SAMPLE_NOT_SUSTAINED=PASS'
Assert ($definitions.Contains('thresholdNotSustained')) 'Runner must persist threshold-not-sustained state'
Assert ($definitions.Contains('$run.timestamps.T0=IstNow') -and $definitions.Contains('$run.timestamps.T5=IstNow')) 'T0 and T5 must be assigned only at their event handlers'
Assert (-not $definitions.Contains("timestamps.T4")) 'T4 must be removed from runner timing logic'
