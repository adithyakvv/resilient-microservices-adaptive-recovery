$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$message){if(-not$ok){throw $message}}
$html=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'gui/index.html') -Raw
foreach($required in @('Applied and verified','Cooldown prevented a repeat action','CPU action applied and verified','Not triggered — CPU threshold was not sustained','Cleanup failed','evaluationHtml(','CPU improvement observed')){Assert ($html.Contains($required)) "GUI report mapping missing: $required"}
Assert ($html.Contains("r.result==='BLOCKED'||r.preflight?.status==='Blocked'") -and $html.Contains('Preflight blocked — no Chaos created and no action requested.')) 'E1 GUI must visibly distinguish and explain a blocked preflight.'
$notTriggered=[pscustomobject]@{result='NOT_TRIGGERED';thresholdNotSustained=$true;chaos=[pscustomobject]@{deleted=$true};cleanup=[pscustomobject]@{restoreVerify=$true};engineEvaluations=@();timestamps=[pscustomobject]@{T1=$null;T2=$null;T3=$null;T4=$null}}
Assert ($notTriggered.result -eq 'NOT_TRIGGERED' -and $notTriggered.chaos.deleted -and $notTriggered.cleanup.restoreVerify) 'Not-triggered fixture must separate experiment and cleanup outcomes'
Assert ($html.Contains('Not triggered — insufficient CPU stress') -and $html.Contains('Experiment outcome: Not triggered')) 'GUI must show not-triggered outcome independently of cleanup'
$failedNoAction=[pscustomobject]@{result='FAILED';engineEvaluations=@();chaos=[pscustomobject]@{deleted=$true};cleanup=[pscustomobject]@{restoreVerify=$true}}
Assert (-not @($failedNoAction.engineEvaluations|Where-Object execute).Count -and $failedNoAction.chaos.deleted -and $failedNoAction.cleanup.restoreVerify) 'No-action cleanup fixture must still expose the not-triggered experiment outcome'
$verified=[pscustomobject]@{result='ACTION_REQUESTED';engineEvaluations=@([pscustomobject]@{decision='INCREASE_CPU';actionVerified=$true},[pscustomobject]@{decision='OBSERVE';reason='cooldown active';actionVerified=$false});cleanup=[pscustomobject]@{restoreVerify=$true}}
Assert (@($verified.engineEvaluations|Where-Object actionVerified).Count -eq 1) 'Verified action mock must remain distinct from cooldown event'
$none=[pscustomobject]@{result='NOT_TRIGGERED';engineEvaluations=@();cleanup=[pscustomobject]@{restoreVerify=$true}}
Assert (@($none.engineEvaluations|Where-Object actionVerified).Count -eq 0) 'No-action mock must not claim an actuator result'
$failed=[pscustomobject]@{result='FAILED';engineEvaluations=@();cleanup=[pscustomobject]@{restoreVerify=$false}}
Assert (-not $failed.cleanup.restoreVerify) 'Failed-cleanup mock must remain failed'
foreach($label in @('Stress injected (T0)','CPU threshold reached (T1)','CPU increase applied (T2)','CPU increase confirmed (T3)','Baseline restored (T5)')){Assert ($html.Contains($label)) "Human timestamp label missing: $label"}
Assert ($html.Contains("e.execute===true&&e.decision==='INCREASE_CPU'&&e.actionVerified===true") -and $html.Contains('Unavailable — no verified execute=true INCREASE_CPU action')) 'GUI must not display T2 as an issued CPU action without a verified execute=true INCREASE_CPU evaluation'
Assert (-not $html.Contains('Post-stress observation (T4)') -and -not $html.Contains('timestamps?.T4')) 'T4 must be absent from GUI timing logic'
'E1_GUI_MOCK_REPORTS=PASS'
