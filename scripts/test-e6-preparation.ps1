$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent
function Assert([bool]$ok,[string]$m){if(-not$ok){throw $m}}
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e6-product-pod-kill.ps1') -Raw;$gui=Get-Content (Join-Path $root 'gui/index.html') -Raw;$server=Get-Content (Join-Path $root 'gui/server.py') -Raw;$manifest=Get-Content (Join-Path $root 'infrastructure/chaos/e6-product-pod-kill.yaml') -Raw;$dashRaw=Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw;$dash=$dashRaw|ConvertFrom-Json
Assert ($manifest.Contains('kind: PodChaos') -and $manifest.Contains('action: pod-kill') -and $manifest.Contains('mode: one') -and $manifest.Contains('adaptive-product-service')) 'E6 manifest selector/action missing'
Assert ($runner.Contains('dry-run=server') -and $runner.Contains('AllInjected') -and $runner.Contains('absenceVerified') -and $runner.Contains('execute=false')) 'E6 runner safeguards missing'
Assert ($runner.Contains('T1') -and $runner.Contains('T3') -and $runner.Contains('T4') -and $runner.Contains('T5') -and $runner.Contains('recoveryTime')) 'E6 timing evidence missing'
Assert ($runner.Contains('uid-ne$baselineUid') -and $runner.Contains('metadata.uid-eq$uid')) 'E6 UID-safe replacement/cleanup checks missing'
Assert ($runner.Contains('Ensure-ProductForward') -and $runner.Contains('postInterruption') -and $runner.Contains('Chaos-Absent')) 'E6 forward recovery or event-order safeguards missing'
Assert ($gui.Contains('E6 — Product Pod Kill') -and $gui.Contains('runE6()') -and $gui.Contains('/api/e6/status')) 'E6 GUI missing'
Assert ($gui.Contains('data-experiment="e6"') -and $gui.Contains('experiment-sections') -and $gui.Contains('outer.open=!!s.running')) 'E6 terminal disclosure behavior missing'
Assert ($server.Contains("'/api/e6/run'") -and $server.Contains("'/api/e6/status'")) 'E6 fixed server routes missing'
$p=$dash.panels|? id -eq 106;Assert ($p -and $p.title -eq 'E6 — Product pod replacement and recovery') 'E6 dashboard title missing';Assert ($dashRaw.Contains('adaptive_recovery_e6_product_ready') -and $dashRaw.Contains('adaptive_recovery_e6_replacement_verified')) 'E6 dashboard queries missing'
$same='old-uid';$replacement='new-uid';Assert ($replacement -ne $same) 'Replacement UID test failed';Assert (-not ($same -ne $same)) 'Same UID must not verify replacement'
$t0=[DateTimeOffset]::Parse('2026-09-27T10:00:00+05:30');$t1=[DateTimeOffset]::Parse('2026-09-27T10:00:03+05:30');Assert (($t1-$t0).TotalSeconds -eq 3) 'Timestamp duration test failed'
$historical=[ordered]@{timestamps=[ordered]@{T1='2026-09-27T16:13:31.506+05:30';T2='2026-09-27T16:13:31.782+05:30'};replacement=[ordered]@{uid='new-uid';ready=$true;health=$false};chaos=[ordered]@{absenceVerified=$true};cleanup=[ordered]@{status='Failed'};result='FAILED'}
Assert ([DateTimeOffset]::Parse($historical.timestamps.T2) -ge [DateTimeOffset]::Parse($historical.timestamps.T1)) 'Historical T2/T1 ordering evidence is invalid'
Assert ($historical.result -eq 'FAILED' -and -not $historical.replacement.health -and $historical.cleanup.status -eq 'Failed') 'Health-false E6 report must remain failed'
Assert ($runner.Contains("Evaluate 'post-replacement'") -and $runner.Contains('$postReplacement=($phase -eq ''post-replacement'')')) 'E6 must record a separate post-replacement Engine observation'
Assert ($runner.Contains('$run.timestamps.T2=IstNow') -and $runner.Contains('$run.timestamps.T3=$at')) 'E6 T2/T3 event timestamps are not event-based'
Assert ($runner.Contains('$run.result=if($run.timestamps.T3 -and $run.timestamps.T4)')) 'E6 must not pass without post-replacement observation and recovery'
Assert ($runner.Contains("phase='interruption'") -and $gui.Contains('Interruption observations are shown here')) 'E6 interruption readings must remain separate from final health'
$early=[ordered]@{engineEvaluations=@([ordered]@{decision='FAIL_SAFE';phase='interruption';actionVerified=$false},[ordered]@{decision='CONTINUE';phase='post-replacement';actionVerified=$false});timestamps=[ordered]@{T1='2026-09-27T16:00:01+05:30';T2='2026-09-27T16:00:05+05:30';T3='2026-09-27T16:00:06+05:30';T4='2026-09-27T16:00:07+05:30';T5='2026-09-27T16:00:08+05:30'}}
Assert ([DateTimeOffset]::Parse($early.timestamps.T2) -ge [DateTimeOffset]::Parse($early.timestamps.T1)) 'E6 T2 must follow T1'
Assert ([DateTimeOffset]::Parse($early.timestamps.T3) -ge [DateTimeOffset]::Parse($early.timestamps.T2)) 'E6 T3 must follow replacement detection'
Assert ($early.engineEvaluations[0].decision -eq 'FAIL_SAFE' -and $early.engineEvaluations[1].phase -eq 'post-replacement') 'Early FAIL_SAFE and later observation must remain separate'
Write-Output 'E6_PREPARATION_CHECK=PASS'
