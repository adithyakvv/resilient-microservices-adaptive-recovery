$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e2-inventory-memory.ps1') -Raw
$manifest=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'infrastructure/chaos/e2-inventory-memory-stress.yaml') -Raw
Assert ($runner.Contains('[int]$Samples = 8') -and $runner.Contains('[int]$SampleIntervalSeconds = 5')) 'E2 must allow eight bounded five-second stress polls'
Assert ($manifest.Contains('duration: 60s') -and $manifest.Contains('size: 128MB') -and $manifest.Contains('workers: 1')) 'E2 fault duration and amount must remain unchanged'
Assert ($runner.Contains('[double]$BaselineGuardRatio = 0.55') -and $runner.Contains('[double]$MemoryThresholdRatio = 0.65') -and $runner.Contains('[double]$SafetyCapRatio = 0.82')) 'E2 guard, action threshold, and safety cap must remain unchanged'
Assert ($runner.Contains('if($reading -and $reading.memoryRatio -ge $SafetyCapRatio)') -and $runner.IndexOf('if($reading -and $reading.memoryRatio -ge $SafetyCapRatio)') -lt $runner.IndexOf('if($above-ge$SustainedSamples')) 'Safety cap must be checked before the actuator'
Assert ($runner.Contains('finally {') -and $runner.Contains('Complete-E2Cleanup -Run $run')) 'UID-safe cleanup and exact restoration must remain mandatory'

$pod=[pscustomobject]@{items=@([pscustomobject]@{metadata=[pscustomobject]@{name='adaptive-inventory-service-demo';uid='same-ready-uid'};status=[pscustomobject]@{phase='Running';containerStatuses=@([pscustomobject]@{name='adaptive-inventory-service';ready=$true})}})}
function Metrics([string]$source,[string]$usage){
  [pscustomobject]@{items=@([pscustomobject]@{metadata=[pscustomobject]@{name='adaptive-inventory-service-demo'};timestamp=$source;window='15s';containers=@([pscustomobject]@{name='adaptive-inventory-service';usage=[pscustomobject]@{memory=$usage}})})}
}
# Reproduce six polls from the saved run: one high source window followed by
# cached copies. Two additional bounded polls permit a later distinct window.
$observed=@('22:45:16','22:45:21','22:45:27','22:45:33','22:45:38','22:45:44','22:45:50','22:45:56')
$sources=@('22:45:05','22:45:05','22:45:21','22:45:21','22:45:21','22:45:21','22:45:21','22:45:55')
$previous=$null;$above=0;$atSix=0
for($i=0;$i -lt $observed.Count;$i++){
  $source='2026-09-28T'+$sources[$i]+'+05:30'
  $at=[DateTimeOffset]::Parse('2026-09-28T'+$observed[$i]+'+05:30')
  $usage=if($i -lt 2){'262300Ki'}else{'388856Ki'}
  $sample=Get-E2MemorySample -Metrics (Metrics $source $usage) -Pods $pod -LimitBytes (512MB) -ObservedAt $at -PreviousSample $previous
  if($sample.available){$previous=$sample;if($sample.memoryRatio -ge 0.65){$above++}else{$above=0}}
  if($i -eq 5){$atSix=$above}
}
Assert ($atSix -eq 1) 'The original six polls must yield only one distinct high sample'
Assert ($above -eq 2) 'Eight polls must allow a second distinct above-threshold source window'
Assert ($previous.memoryRatio -lt 0.82) 'The second high sample must remain below the unchanged safety cap'
Assert (([DateTimeOffset]::Parse('2026-09-28T22:45:56+05:30')-[DateTimeOffset]::Parse('2026-09-28T22:45:10+05:30')).TotalSeconds -lt 60) 'The added poll remains within the 60-second fault duration'
'E2_TIMING_TESTS=PASS'
