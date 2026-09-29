$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Force
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
$now = [DateTimeOffset]::Parse('2026-09-28T16:30:00Z')
$pods = [pscustomobject]@{items=@([pscustomobject]@{metadata=[pscustomobject]@{name='adaptive-inventory-service-abc';uid='uid-1'};status=[pscustomobject]@{phase='Running';containerStatuses=@([pscustomobject]@{name='adaptive-inventory-service';ready=$true})}})}
function Metrics([string]$time,[string]$memory='250000Ki',[string]$window='10.111s') {
  [pscustomobject]@{items=@([pscustomobject]@{metadata=[pscustomobject]@{name='adaptive-inventory-service-abc'};timestamp=$time;window=$window;containers=@([pscustomobject]@{name='adaptive-inventory-service';usage=[pscustomobject]@{memory=$memory}})})}
}
$a=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:29:25Z') -Pods $pods -LimitBytes (512MB) -ObservedAt $now
$b=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:29:40Z') -Pods $pods -LimitBytes (512MB) -ObservedAt $now -PreviousSample $a
$c=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:29:55Z') -Pods $pods -LimitBytes (512MB) -ObservedAt $now -PreviousSample $b
Assert ($a.available -and $b.available -and $c.available) 'Three fresh samples must be accepted'
Assert ($a.window -eq '10.111s' -and $a.podUid -eq 'uid-1' -and $a.metricsTimestamp -like '2026-09-28T16:29:25*') 'PodMetrics timestamp, window, and pod UID must be retained'
Assert ((Test-E2BaselineSamples -Samples @($a,$b,$c) -GuardRatio 0.55 -Required 3).passed) 'Three below-guard samples should pass'
$high=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:29:55Z' '290800Ki') -Pods $pods -LimitBytes (512MB) -ObservedAt $now -PreviousSample $b
Assert ($high.memoryRatio -ge 0.55) 'Historical above-guard reading must calculate correctly'
Assert (-not (Test-E2BaselineSamples -Samples @($a,$b,$high) -GuardRatio 0.55 -Required 3).passed) 'Fresh above-guard sample must block'
$duplicate=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:29:40Z' '249000Ki') -Pods $pods -LimitBytes (512MB) -ObservedAt $now -PreviousSample $b
Assert (-not $duplicate.available -and $duplicate.reason -match 'Duplicate') 'Repeated timestamp must not count even if usage changes'
$stale=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:28:00Z') -Pods $pods -LimitBytes (512MB) -ObservedAt $now
Assert (-not $stale.available -and $stale.reason -match 'stale') 'Old Metrics API reading must be rejected'
Assert (-not (Test-E2BaselineSamples -Samples @($a,$a,$c) -GuardRatio 0.55 -Required 3).passed) 'Duplicate samples must not satisfy preflight'
$accepted=@();$previous=$null
foreach($source in @('2026-09-28T16:29:25Z','2026-09-28T16:29:25Z','2026-09-28T16:29:40Z','2026-09-28T16:29:40Z','2026-09-28T16:29:55Z')){
  $candidate=Get-E2MemorySample -Metrics (Metrics $source) -Pods $pods -LimitBytes (512MB) -ObservedAt $now -PreviousSample $previous
  if($candidate.available){$accepted+=,$candidate;$previous=$candidate}
}
Assert ($accepted.Count -eq 3) 'Repeated Metrics API timestamps must be retried until three distinct samples arrive'
Assert ((Test-E2BaselineSamples -Samples $accepted -GuardRatio 0.55 -Required 3).passed) 'Three fresh timestamps after duplicates must pass'
$timeout=Test-E2BaselineSamples -Samples @($a,$b) -GuardRatio 0.55 -Required 3
Assert (-not $timeout.passed -and $timeout.reason -match 'timeout' -and $timeout.reason.Contains($a.metricsTimestamp) -and $timeout.reason.Contains($b.metricsTimestamp)) 'Timeout must stay blocked and list the distinct timestamps obtained'
$wrongWindow=Get-E2MemorySample -Metrics (Metrics '2026-09-28T16:29:55Z' '250000Ki' '') -Pods $pods -LimitBytes (512MB) -ObservedAt $now
Assert (-not $wrongWindow.available) 'Missing sampling window must be rejected'
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e2-inventory-memory.ps1') -Raw
Assert ($runner.Contains('elseif(-not $run.preflight.blocked)') -and $runner.Contains('Test-E2BaselineSamples') -and $runner.Contains("`$run.experimentOutcome='NOT_STARTED'")) 'Guard rejection must prevent Chaos apply and Engine evaluation'
Assert ($runner.Contains('$script:lastMetricsSample=$sample') -and $runner.Contains('-PreviousSample $script:lastMetricsSample') -and $runner.Contains('BaselineTimeoutSeconds = 65')) 'Runner must remember accepted samples across calls and retry for a bounded period'
'E2_BASELINE_TESTS=PASS'
