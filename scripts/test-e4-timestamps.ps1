$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$runner = Get-Content (Join-Path $PSScriptRoot 'run-e4-order-http500.ps1') -Raw
$reportPath = Join-Path $root 'reports/e4-order-http500-E4-20260928-115817+0530.json'
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
if ($report.runId -ne 'E4-20260928-115817+0530' -or $report.result -ne 'PASSED') { throw 'Historical E4 report identity/result changed.' }
if ($report.timestamps -or $report.timestampEvidence) { throw 'Historical report was unexpectedly edited with lifecycle timestamps.' }
if (@($report.measurements | Where-Object { $_.probe.at }).Count -ne 6) { throw 'Expected six saved per-probe timestamps in the historical report.' }
if (@($report.engineEvaluations | Where-Object { $_.at }).Count -ne 4) { throw 'Expected four saved Engine evaluation timestamps in the historical report.' }
foreach ($event in 'T0','T1','T2','T3','T4','T5') {
    if (-not $runner.Contains("Record-E4Timestamp '$event'")) { throw "Future runner does not capture $event at its event site." }
}
foreach ($needle in @('timestampDefinitions=$e4TimestampDefinitions','timestampEvidence=[ordered]','durationDefinitions=[ordered]','Save-Report -Path $reportPath')) {
    if (-not $runner.Contains($needle)) { throw "Future report persistence contract missing: $needle" }
}
if (-not $runner.Contains("Record-E4Timestamp 'T2' ([string]`$eval.at)")) { throw 'T2 must come from the actual execute=true Engine response timestamp.' }
if (-not $runner.Contains("if(`$report.recovery.latencyRecovered){Record-E4Timestamp 'T4'")) { throw 'T4 must be recorded only when the recovery predicate is satisfied.' }
if (-not $runner.Contains("if(`$report.cleanup.faultOff -eq `$true -and `$report.cleanup.ready -eq `$true){Record-E4Timestamp 'T5'")) { throw 'T5 must wait for final cleanup and readiness checks.' }
$saveDefinition = [regex]::Match($runner, '(?m)^function Save-Report\{[^\r\n]*\}').Value
$recordDefinition = [regex]::Match($runner, '(?m)^function Record-E4Timestamp\([^\r\n]*\}').Value
if (-not $saveDefinition -or -not $recordDefinition) { throw 'Timestamp persistence helper could not be isolated for a non-live test.' }
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('e4-timestamp-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    $progressPath = Join-Path $testDir 'progress.json'
    $reportPath = Join-Path $testDir 'report.json'
    $report = [ordered]@{ timestamps=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T4=$null;T5=$null}; timestampEvidence=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T4=$null;T5=$null} }
    Invoke-Expression $saveDefinition
    Invoke-Expression $recordDefinition
    Record-E4Timestamp 'T0' '2026-09-28T10:00:00+05:30' 'confirmed enable response'
    Record-E4Timestamp 'T0' '2026-09-28T10:00:03+05:30' 'must not overwrite the event'
    $progress = Get-Content $progressPath -Raw | ConvertFrom-Json
    $final = Get-Content $reportPath -Raw | ConvertFrom-Json
    if ($progress.timestamps.T0 -ne $final.timestamps.T0 -or $final.timestampEvidence.T0 -ne 'confirmed enable response') { throw 'Event timestamp/evidence was not persisted identically to progress and report, or was overwritten.' }
} finally {
    Remove-Item -LiteralPath $testDir -Recurse -Force
}
Write-Output 'E4_TIMESTAMPS_TEST=PASS'
