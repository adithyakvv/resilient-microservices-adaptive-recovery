$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e1-postcleanup-telemetry.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not$ok){throw $message}}
$cleanup='2026-09-29T02:14:14+05:30'
$lastStress='2026-09-28T20:44:10Z'
$base=@{phase='after';pod='inventory-new';cpuCores=0.002;sourceTimestamp='2026-09-28T20:45:00Z';window='15s'}
$good=Test-E1PostCleanupSample -Reading $base -CleanupCompletedAt $cleanup -LastStressSourceTimestamp $lastStress -CurrentPodName 'inventory-new' -CurrentPodUid 'new-uid'
Assert $good.passed 'A lower sample from the current Ready pod, with its whole window after cleanup, must pass'
$stale=$base.Clone();$stale.sourceTimestamp='2026-09-28T20:44:20Z'
Assert (-not (Test-E1PostCleanupSample -Reading $stale -CleanupCompletedAt $cleanup -LastStressSourceTimestamp $lastStress -CurrentPodName 'inventory-new' -CurrentPodUid 'new-uid').passed) 'A cached/overlapping stress window must not be republished'
$missing=$base.Clone();$missing.Remove('sourceTimestamp')
Assert (-not (Test-E1PostCleanupSample -Reading $missing -CleanupCompletedAt $cleanup -LastStressSourceTimestamp $lastStress -CurrentPodName 'inventory-new' -CurrentPodUid 'new-uid').passed) 'A missing Metrics API source timestamp must be unavailable'
$wrongPod=$base.Clone();$wrongPod.pod='inventory-old'
Assert (-not (Test-E1PostCleanupSample -Reading $wrongPod -CleanupCompletedAt $cleanup -LastStressSourceTimestamp $lastStress -CurrentPodName 'inventory-new' -CurrentPodUid 'new-uid').passed) 'A non-current pod sample must be unavailable'
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e1-inventory-cpu.ps1') -Raw
Assert ($runner.Contains("Read-CPU 'after' `$false `$false")) 'Candidate after readings must not be published before freshness validation'
Assert ($runner.Contains('Test-ChaosAbsent') -and $runner.Contains('Test-E1PostCleanupSample')) 'Absence and source-window freshness must be verified'
Assert ($runner.Contains('Mark-E1TelemetryUnavailable') -and $runner.Contains('/api/recovery/e1/unavailable')) 'No valid final reading must invalidate the held gauge, not publish zero'
Assert ($runner.Contains('Wait-E1Scrape') -and $runner.Contains('postCleanupTelemetry')) 'Prometheus scrape and telemetry verdict must be separate from run status'
'E1_POSTCLEANUP_TELEMETRY_TESTS=PASS'
