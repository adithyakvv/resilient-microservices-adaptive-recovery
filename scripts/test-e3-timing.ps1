$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e3-reporting.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}

# The saved report is read-only input: its incorrect historical median fields
# and absent lifecycle timestamps must remain untouched.
$reportPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'reports/e3-order-inventory-delay-20260928-113950+0530.json'
$historical=Get-Content $reportPath -Raw|ConvertFrom-Json
Assert ($historical.runId -eq 'E3-20260928-113950+0530') 'Unexpected historical fixture'
Assert (-not $historical.PSObject.Properties['timestamps']) 'Historical report unexpectedly contains lifecycle timestamps'
Assert ([double]$historical.medians.before -eq 90.284) 'Historical report was unexpectedly rewritten'

# Median regression for the exact screenshot readings and during/after values.
$before=@($historical.measurements|Where-Object phase -eq 'before'|ForEach-Object {[double]$_.latencyMs})
$during=@($historical.measurements|Where-Object phase -eq 'during'|ForEach-Object {[double]$_.latencyMs})
$after=@($historical.measurements|Where-Object phase -eq 'after'|ForEach-Object {[double]$_.latencyMs})
Assert ((Get-E3Median -Values $before) -eq 22.944) 'Before median must be 22.944 ms'
Assert ((Get-E3Median -Values $during) -eq 1022.759) 'During median must be 1022.759 ms'
Assert ((Get-E3Median -Values $after) -eq 17.527) 'After median must be 17.527 ms'
Assert ((Get-E3Median -Values @(1,2,3,4)) -eq 2.5) 'Even-sized median must average the two middle values'
Assert ($null -eq (Get-E3Median -Values @())) 'An empty phase must have an unavailable median'

# Event setter persists only observed values and evidence; a progress snapshot
# after each event contains the timestamp already observed at that point.
$run=[ordered]@{timestamps=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T4=$null;T5=$null};timestampEvidence=[ordered]@{}}
$snapshots=@()
$events=@(
  @{event='T0';timestamp='2026-09-28T11:39:50.000+05:30';source='delay endpoint confirmed enabled'},
  @{event='T1';timestamp='2026-09-28T11:39:55.938+05:30';source='first during probe timestamp'},
  @{event='T2';timestamp='2026-09-28T11:40:00.320+05:30';source='Engine response timestamp'},
  @{event='T3';timestamp='2026-09-28T11:40:00.500+05:30';source='delay endpoint confirmed disabled'},
  @{event='T4';timestamp='2026-09-28T11:40:01.435+05:30';source='first after probe timestamp'},
  @{event='T5';timestamp='2026-09-28T11:40:04.000+05:30';source='cleanup and readiness verified'}
)
foreach($index in 0..($events.Count-1)){
  $event=$events[$index]
  Assert (Set-E3ObservedTimestamp -Run $run -Event $event.event -Timestamp $event.timestamp -Evidence $event.source) "Could not set $($event.event)"
  $snapshot=($run|ConvertTo-Json -Depth 5)|ConvertFrom-Json
  $snapshots+=$snapshot
  foreach($prior in 0..$index){$name=$events[$prior].event;Assert ($snapshot.timestamps.$name -eq $events[$prior].timestamp) "$name did not persist in the event-time snapshot"}
  if($index -lt ($events.Count-1)){$nextName=[string]$events[$index+1].event;$nextValue=$snapshot.timestamps.PSObject.Properties[$nextName].Value;Assert (-not $nextValue) 'Future event was populated early'}
}
Assert (-not (Set-E3ObservedTimestamp -Run $run -Event 'T0' -Timestamp '2026-09-28T11:39:51+05:30' -Evidence 'replacement')) 'Observed lifecycle timestamps must not be overwritten'
Assert ($run.timestampEvidence.T1 -eq 'first during probe timestamp') 'Timestamp evidence source was not retained'

$runner=Get-Content (Join-Path $PSScriptRoot 'run-e3-order-inventory-delay.ps1') -Raw
Assert ($runner.Contains('function Record-E3Event') -and $runner.Contains('Set-E3ObservedTimestamp') -and $runner.Contains('Save-Run;return $true')) 'Event persistence helper must save each newly observed timestamp immediately'
foreach($call in @("Record-E3Event 'T0' (IstNow)","Record-E3Event 'T1' `$m.timestamp","Record-E3Event 'T2' `$decisionAt","Record-E3Event 'T3' (IstNow)","Record-E3Event 'T4' `$m.timestamp","Record-E3Event 'T5' (IstNow)")){Assert ($runner.Contains($call)) "Runner is missing lifecycle event capture: $call"}
$engineCall=$runner.IndexOf('$a=Invoke-RestMethod')
$decisionTime=$runner.IndexOf('$decisionAt=IstNow',$engineCall)
Assert ($engineCall -ge 0 -and $decisionTime -gt $engineCall) 'T2 must be timestamped after the actual Engine response, not before it'
Assert ($runner.Contains('Get-E3Median -Values $values')) 'Runner phase medians must use the tested median helper'
'E3_TIMING_AND_MEDIAN_TESTS=PASS'
