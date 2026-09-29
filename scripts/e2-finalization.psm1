function Resolve-E2ChaosLookup {
  param(
    [Parameter(Mandatory=$true)][int]$ExitCode,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Output,
    [Parameter(Mandatory=$false)][AllowEmptyString()][string]$ExpectedUid
  )

  if ($ExitCode -eq 0) {
    try {
      $resource = $Output | ConvertFrom-Json -ErrorAction Stop
      $uid = [string]$resource.metadata.uid
      if (-not $uid) { return [pscustomobject]@{ state='Unknown'; uid=$null; reason='Successful lookup returned no UID' } }
      if ($ExpectedUid -and $uid -eq $ExpectedUid) {
        return [pscustomobject]@{ state='PresentOwned'; uid=$uid; reason='Live UID matches this run' }
      }
      return [pscustomobject]@{ state='PresentOther'; uid=$uid; reason='Live UID does not match this run' }
    } catch {
      return [pscustomobject]@{ state='Unknown'; uid=$null; reason=('Could not parse Chaos lookup: ' + $_.Exception.Message) }
    }
  }

  if ($Output -match '(?i)(NotFound|not found)') {
    return [pscustomobject]@{ state='Absent'; uid=$null; reason='Kubernetes confirmed the Chaos object is NotFound' }
  }
  return [pscustomobject]@{ state='Unknown'; uid=$null; reason=($Output.Trim()) }
}

function Complete-E2Cleanup {
  param(
    [Parameter(Mandatory=$true)]$Run,
    [Parameter(Mandatory=$true)][bool]$DeletionRequested,
    [Parameter(Mandatory=$true)][bool]$DeleteCommandAccepted,
    [Parameter(Mandatory=$true)][string]$DeletionOutcome,
    [Parameter(Mandatory=$true)][bool]$ChaosAbsenceVerified,
    [Parameter(Mandatory=$true)][bool]$BaselineVerified,
    [Parameter(Mandatory=$true)][bool]$RolloutVerified,
    [Parameter(Mandatory=$true)][bool]$ReadinessVerified,
    [Parameter(Mandatory=$true)][string]$VerifiedAt,
    [Parameter(Mandatory=$false)][string]$ErrorMessage,
    [switch]$CheckOnly
  )

  $Run.cleanup.attempted = $true
  if ($CheckOnly) {
    $Run.cleanup.status = 'Not applicable — no live fault was created'
    $Run.cleanup.resourceDeleted = $false
    $Run.cleanup.absenceVerified = $false
    $Run.cleanup.baselineVerified = $Run.cleanup.baselineVerified -eq $true
    $Run.cleanup.rolloutVerified = $false
    $Run.cleanup.readinessVerified = $Run.readiness.before -eq $true
    $Run.cleanup.restoreVerify = $true
    $Run.cleanup.error = $null
    $Run.chaos.deletionRequested = $false
    $Run.chaos.deletionOutcome = 'not applicable — no live fault was created'
    $Run.chaos.deleted = $false
    $Run.chaos.absenceVerified = $false
    $Run.timestamps.T5 = $null
    $Run.timestamps.timeToStableState = $null
    $Run.runStatus = 'Completed'
    return $true
  }

  $deleted = $DeletionRequested -and $DeleteCommandAccepted -and $ChaosAbsenceVerified
  $cleanupPassed = $ChaosAbsenceVerified -and $BaselineVerified -and $RolloutVerified -and $ReadinessVerified
  $Run.chaos.deletionRequested = $DeletionRequested
  $Run.chaos.deletionOutcome = $DeletionOutcome
  $Run.chaos.deleted = $deleted
  $Run.chaos.absenceVerified = $ChaosAbsenceVerified
  $Run.cleanup.deletionRequested = $DeletionRequested
  $Run.cleanup.deletionOutcome = $DeletionOutcome
  $Run.cleanup.resourceDeleted = $deleted
  $Run.cleanup.absenceVerified = $ChaosAbsenceVerified
  $Run.cleanup.baselineVerified = $BaselineVerified
  $Run.cleanup.rolloutVerified = $RolloutVerified
  $Run.cleanup.readinessVerified = $ReadinessVerified
  $Run.cleanup.restoreVerify = $cleanupPassed
  $Run.cleanup.status = if ($cleanupPassed) { 'Passed' } else { 'Failed' }
  $Run.cleanup.error = $ErrorMessage

  if ($cleanupPassed) {
    $Run.timestamps.T5 = $VerifiedAt
    $Run.timestampEvidence.T5 = 'Chaos absence, exact baseline resources, rollout, and Inventory readiness were independently verified.'
  } else {
    $Run.timestamps.T5 = $null
    $Run.timestamps.timeToStableState = $null
  }
  $Run.runStatus = if ($cleanupPassed) { 'Completed' } else { 'Failed' }
  return $cleanupPassed
}

function Write-E2RunArtifacts {
  <#
    Persist progress and the run report independently. Progress is a live UI
    convenience and may be locked by a concurrent reader; it must never
    change the experiment or cleanup verdict, nor prevent the authoritative
    per-run report from being written.

    WriteText is injectable for regression tests. It receives path and JSON.
  #>
  param(
    [Parameter(Mandatory=$true)]$Run,
    [Parameter(Mandatory=$true)][string]$ProgressPath,
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [Parameter(Mandatory=$false)][scriptblock]$WriteText
  )

  if (-not $WriteText) {
    $WriteText = {
      param($Path, $Json)
      [System.IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    }
  }

  if (-not $Run.Contains('reportWriting')) {
    $Run['reportWriting'] = [ordered]@{
      progressStatus='Pending'; progressError=$null
      finalReportStatus='Pending'; finalReportError=$null
    }
  }

  # Best effort only. Capture this failure in its own status; do not throw or
  # mutate experimentOutcome, result, cleanup.status, or cleanup.error.
  try {
    $progressJson = $Run | ConvertTo-Json -Depth 16
    & $WriteText $ProgressPath $progressJson
    $Run.reportWriting.progressStatus = 'Written'
    $Run.reportWriting.progressError = $null
  } catch {
    $Run.reportWriting.progressStatus = 'Failed'
    $Run.reportWriting.progressError = $_.Exception.Message
  }

  # The authoritative report write always gets its own attempt, regardless
  # of progress-file success. Set status before serializing so the report
  # records the final write attempt's state.
  $Run.reportWriting.finalReportStatus = 'Written'
  $Run.reportWriting.finalReportError = $null
  try {
    $reportJson = $Run | ConvertTo-Json -Depth 16
    & $WriteText $ReportPath $reportJson
  } catch {
    $Run.reportWriting.finalReportStatus = 'Failed'
    $Run.reportWriting.finalReportError = $_.Exception.Message

    # If the progress target is available, publish the report-write failure
    # there. This is also best effort and cannot alter either outcome.
    try {
      $progressJson = $Run | ConvertTo-Json -Depth 16
      & $WriteText $ProgressPath $progressJson
    } catch {
      $Run.reportWriting.progressStatus = 'Failed'
      $Run.reportWriting.progressError = $_.Exception.Message
    }
  }

  return [pscustomobject]@{
    progressStatus = $Run.reportWriting.progressStatus
    progressError = $Run.reportWriting.progressError
    finalReportStatus = $Run.reportWriting.finalReportStatus
    finalReportError = $Run.reportWriting.finalReportError
  }
}

Export-ModuleMember -Function Resolve-E2ChaosLookup, Complete-E2Cleanup, Write-E2RunArtifacts
