$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e2-finalization.psm1') -Force

function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-Run {
  return [ordered]@{
    runId='E2-test-already-absent';runStatus='Running';result='ACTION_REQUESTED';experimentOutcome='MEMORY_ACTION_REQUESTED'
    engineEvaluations=@([ordered]@{decision='INCREASE_MEMORY';execute=$true;actionVerified=$true})
    timestamps=[ordered]@{T0='2026-09-28T08:06:10+05:30';T1='2026-09-28T08:06:27+05:30';T2='2026-09-28T08:06:33+05:30';T3='2026-09-28T08:06:33+05:30';T5=$null;timeToStableState=$null}
    timestampEvidence=[ordered]@{}
    chaos=[ordered]@{name='adaptive-inventory-e2-memory';uid='fcec912c-db8f-4b64-af68-710d50ddf978';created=$true;deletionRequested=$false;deleted=$false;absenceVerified=$false;deletionOutcome=$null}
    cleanup=[ordered]@{attempted=$false;deletionRequested=$false;deletionOutcome=$null;resourceDeleted=$false;absenceVerified=$false;baselineVerified=$false;rolloutVerified=$false;readinessVerified=$false;restoreVerify=$false;status=$null;error=$null}
    reportWriting=[ordered]@{progressStatus='Pending';progressError=$null;finalReportStatus='Pending';finalReportError=$null}
    readiness=[ordered]@{before=$true;after=$true}
    resources=[ordered]@{before=[ordered]@{cpuRequest='100m';cpuLimit='500m';memoryRequest='256Mi';memoryLimit='512Mi'};during=@([ordered]@{cpuRequest='100m';cpuLimit='500m';memoryRequest='384Mi';memoryLimit='768Mi'});after=[ordered]@{cpuRequest='100m';cpuLimit='500m';memoryRequest='256Mi';memoryLimit='512Mi'}}
  }
}

# Exact regression shape: the action is verified, the fault has already been
# removed (NotFound), and cleanup must pass only after independent checks.
$notFound=Resolve-E2ChaosLookup -ExitCode 1 -Output 'Error from server (NotFound): stresschaos.chaos-mesh.org "adaptive-inventory-e2-memory" not found' -ExpectedUid 'fcec912c-db8f-4b64-af68-710d50ddf978'
Assert ($notFound.state -eq 'Absent') 'Kubernetes NotFound must be classified as absent'
$run=New-Run
$pass=Complete-E2Cleanup -Run $run -DeletionRequested $false -DeleteCommandAccepted $false -DeletionOutcome 'already absent; deletion not needed' -ChaosAbsenceVerified $true -BaselineVerified $true -RolloutVerified $true -ReadinessVerified $true -VerifiedAt '2026-09-28T08:07:00+05:30'
Assert $pass 'Already-absent Chaos plus verified cleanup conditions should pass'
Assert ($run.runStatus -eq 'Completed' -and $run.cleanup.status -eq 'Passed' -and $run.cleanup.restoreVerify) 'Cleanup did not complete after independent checks'
Assert (-not $run.chaos.deletionRequested -and -not $run.chaos.deleted -and $run.chaos.absenceVerified) 'Already-absent case must distinguish no deletion from verified absence'
Assert ($run.chaos.deletionOutcome -eq 'already absent; deletion not needed') 'Already-absent deletion outcome is inaccurate'
Assert ($run.timestamps.T5 -eq '2026-09-28T08:07:00+05:30') 'T5 must be recorded after all cleanup checks pass'
Assert ($run.experimentOutcome -eq 'MEMORY_ACTION_REQUESTED' -and $run.engineEvaluations[0].actionVerified) 'Cleanup must preserve the verified INCREASE_MEMORY experiment outcome'

# A real deletion is distinct from absence verification.
$deletedRun=New-Run
$deletedPass=Complete-E2Cleanup -Run $deletedRun -DeletionRequested $true -DeleteCommandAccepted $true -DeletionOutcome 'delete command accepted; absence independently verified' -ChaosAbsenceVerified $true -BaselineVerified $true -RolloutVerified $true -ReadinessVerified $true -VerifiedAt '2026-09-28T08:07:01+05:30'
Assert ($deletedPass -and $deletedRun.chaos.deleted -and $deletedRun.chaos.deletionRequested -and $deletedRun.chaos.absenceVerified) 'Confirmed delete must record request, outcome, and absence separately'

# A resource snapshot alone is insufficient: any failed independent check
# keeps cleanup Failed and must not produce T5.
$restoreFailed=New-Run
$restorePass=Complete-E2Cleanup -Run $restoreFailed -DeletionRequested $false -DeleteCommandAccepted $false -DeletionOutcome 'already absent; deletion not needed' -ChaosAbsenceVerified $true -BaselineVerified $false -RolloutVerified $true -ReadinessVerified $true -VerifiedAt '2026-09-28T08:07:02+05:30' -ErrorMessage 'baseline mismatch'
Assert (-not $restorePass -and $restoreFailed.runStatus -eq 'Failed' -and $restoreFailed.cleanup.status -eq 'Failed') 'Baseline mismatch must fail cleanup'
Assert (-not $restoreFailed.timestamps.T5) 'T5 must remain unavailable unless every cleanup check passes'

$readinessFailed=New-Run
$null=Complete-E2Cleanup -Run $readinessFailed -DeletionRequested $false -DeleteCommandAccepted $false -DeletionOutcome 'already absent; deletion not needed' -ChaosAbsenceVerified $true -BaselineVerified $true -RolloutVerified $true -ReadinessVerified $false -VerifiedAt '2026-09-28T08:07:03+05:30'
Assert (-not $readinessFailed.cleanup.restoreVerify -and -not $readinessFailed.timestamps.T5) 'Readiness failure must keep cleanup failed and T5 unavailable'

# Regression for E2-20260928-104553+0530: the progress file is locked after a
# verified memory action and independently successful cleanup. The progress
# error must remain a report-writing status, while the final report is still
# written with the successful experiment and cleanup outcomes intact.
$lockedProgress=New-Run
$null=Complete-E2Cleanup -Run $lockedProgress -DeletionRequested $false -DeleteCommandAccepted $false -DeletionOutcome 'already absent; deletion not needed' -ChaosAbsenceVerified $true -BaselineVerified $true -RolloutVerified $true -ReadinessVerified $true -VerifiedAt '2026-09-28T10:46:24+05:30'
$script:capturedFinalReport=$null
$lockWriter={
  param($Path,$Json)
  if ($Path -eq 'e2-progress.json') { throw "The process cannot access the file 'e2-progress.json' because it is being used by another process." }
  if ($Path -eq 'e2-final.json') { $script:capturedFinalReport=$Json; return }
  throw "Unexpected output path: $Path"
}
$writeResult=Write-E2RunArtifacts -Run $lockedProgress -ProgressPath 'e2-progress.json' -ReportPath 'e2-final.json' -WriteText $lockWriter
$savedFinal=$script:capturedFinalReport | ConvertFrom-Json
Assert ($writeResult.progressStatus -eq 'Failed' -and $writeResult.progressError -match 'being used by another process') 'Progress lock must be separately reported'
Assert ($writeResult.finalReportStatus -eq 'Written' -and $savedFinal.reportWriting.finalReportStatus -eq 'Written') 'Progress lock must not prevent the independent final-report write'
Assert ($savedFinal.reportWriting.progressStatus -eq 'Failed') 'Final report must preserve the progress-write failure separately'
Assert ($savedFinal.experimentOutcome -eq 'MEMORY_ACTION_REQUESTED' -and $savedFinal.engineEvaluations[0].decision -eq 'INCREASE_MEMORY' -and $savedFinal.engineEvaluations[0].execute -and $savedFinal.engineEvaluations[0].actionVerified) 'Progress lock must not overwrite the verified memory-action outcome'
Assert ($savedFinal.cleanup.status -eq 'Passed' -and $savedFinal.cleanup.restoreVerify -and $savedFinal.timestamps.T5) 'Progress lock must not overwrite successful cleanup/restoration'
Assert (-not $savedFinal.cleanup.error -and $savedFinal.result -eq 'ACTION_REQUESTED') 'Progress lock must not be mislabeled as cleanup failure or experiment failure'

$runner=Get-Content (Join-Path $PSScriptRoot 'run-e2-inventory-memory.ps1') -Raw
Assert ($runner.Contains("Import-Module (Join-Path `$PSScriptRoot 'e2-finalization.psm1')")) 'E2 runner does not use tested finalization helper'
Assert ($runner.Contains('Write-E2RunArtifacts') -and $runner.Contains('progress report write failed')) 'E2 progress writes must be best-effort and final report writes independent'
Assert ($runner.Contains('Invoke-KubectlCaptured') -and $runner.Contains('Resolve-E2ChaosLookup')) 'E2 runner must classify NotFound without throwing out of finally'
Assert ($runner.Contains('if($diff){') -and $runner.Contains("K @('rollout','status','deployment/adaptive-inventory-service'")) 'Restoration/rollout must run independently and only patch differing baseline'
Assert ($runner.Contains('-ChaosAbsenceVerified $chaosAbsent') -and $runner.Contains('-BaselineVerified $baselineVerified') -and $runner.Contains('-RolloutVerified $rolloutVerified') -and $runner.Contains('-ReadinessVerified $readinessVerified')) 'T5 must consume independent cleanup checks'
Assert (-not $runner.Contains('$run.experimentOutcome=''FAILED''')) 'Cleanup failure must not overwrite the experiment outcome'
'E2_FINALIZATION_TESTS=PASS'
