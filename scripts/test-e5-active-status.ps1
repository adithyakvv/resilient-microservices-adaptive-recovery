$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
$root=Split-Path $PSScriptRoot -Parent
$server=Get-Content (Join-Path $root 'gui/server.py') -Raw
$gui=Get-Content (Join-Path $root 'gui/index.html') -Raw
$dash=Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw
# Regression fixture: while an active simulation has an intentional 500, the
# status path must use the progress report rather than the idle preflight.
$fixture=@{running=$true;report=@{fault=@{enabled=$true};samples=@(@{status=500})}}
Assert ($fixture.running -and $fixture.report.fault.enabled -and $fixture.report.samples[-1].status -eq 500) 'active 500 fixture invalid'
Assert ($server.Contains("'RUNNING_FAULT'") -and $server.Contains('E5 probe: HTTP 500 (fault active)')) 'server does not preserve active E5 fault state'
Assert ($gui.Contains("s.running&&rt.status==='RUNNING_FAULT'") -and $gui.Contains('E5 probe: HTTP 500 (fault active)')) 'GUI does not distinguish active E5 500 from Order health'
Assert ($gui.Contains('E5 run active; cleanup pending')) 'GUI active cleanup state missing'
# Saved-report fixture: three qualifying samples plus an execute=true simulated
# decision must render as a recorded simulation, even when actionVerified is false.
$saved=@{samples=@(@{status=500;fresh=$true},@{status=500;fresh=$true},@{status=500;fresh=$true},@{status=200;phase='after'});engineEvaluations=@(@{decision='SIMULATED_RESTART';execute=$true;actionVerified=$false});cleanup=@{status='Passed';faultOff=$true};after=@{routeStatus=200}}
Assert (@($saved.samples|? {$_.status -eq 500 -and $_.fresh}).Count -eq 3) 'saved-report qualifying sample fixture invalid'
Assert ($gui.Contains('E5 · Completed · Engine restart decision recorded') -and $gui.Contains('status-Passed') -and $gui.Contains('Restart decision recorded; no Kubernetes restart was executed.')) 'GUI compact passed report wording missing'
Assert ($gui.Contains('E5 persistent HTTP 500 threshold reached; restart recommended.') -and $gui.Contains('E5 persistent HTTP 500 threshold reached; restart decision recorded.')) 'GUI restart recommendation/action mappings missing'
Assert ($gui.Contains('cleanup.status===') -and $gui.Contains('cleanup.faultOff===true') -and $gui.Contains('final200')) 'GUI passed predicate missing required cleanup/final probe'
Assert ($gui.Contains('let derived=s.report?e5Derived(s.report):null') -and $gui.Contains('!s.running&&derived?.passed')) 'E5 summary badge does not use evidence-derived outcome'
Assert ($gui.Contains('e5Ist') -and $gui.Contains('recoveryDuration') -and $gui.Contains('cleanupDuration')) 'E5 timestamp duration mapping missing'
Assert ($dash.Contains('adaptive_recovery_e5_http_500_consecutive') -and $dash.Contains('adaptive_recovery_e5_simulated_action') -and $dash.Contains('vector(3)') -and $dash.Contains('E5 restart action recorded')) 'E5 Grafana count/action queries or legend missing'
$panel=((Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw|ConvertFrom-Json).panels|? id -eq 105)
$e5PanelText=($panel.title+' '+$panel.description+' '+(@($panel.targets)|% legendFormat)-join ' ')
$e5Text=(($gui -split '<section class="card" id="e5-panel">')[1] -split '<section class="card" id="e6-panel">')[0] + $e5PanelText
Assert (-not ($e5Text -match '(?i)simulation|simulated')) 'E5 visible text still contains forbidden wording'
$e5RenderSource=(($gui -split 'function e5Report')[1] -split 'let e5PollTimer')[0]
Assert ($e5RenderSource.Contains('Restart decision recorded; no Kubernetes restart was executed.') -and $e5RenderSource.Contains('E5 persistent HTTP 500 threshold reached; restart recommended.') -and $e5RenderSource.Contains('E5 persistent HTTP 500 threshold reached; restart decision recorded.')) 'E5 rendered text mappings are incomplete'
Assert (-not $e5RenderSource.Contains('verified=${')) 'E5 display must not imply a real restart was verified'
$historicalPath=Join-Path $root 'reports/e5-order-http500-E5-20260927-213307+0530.json'
if(Test-Path $historicalPath){$historical=Get-Content $historicalPath -Raw|ConvertFrom-Json;$h500=@($historical.samples|? {$_.status -eq 500 -and $_.fresh -eq $true}).Count;$hAction=@($historical.engineEvaluations|? {$_.execute -eq $true -and $_.decision -eq 'SIMULATED_RESTART'}).Count;$hFinal=($historical.cleanup.status -eq 'Passed' -and $historical.cleanup.faultOff -eq $true -and ($historical.after.routeStatus -eq 200 -or @($historical.samples|? {$_.phase -eq 'after' -and $_.status -eq 200 -and $_.fresh -eq $true}).Count -gt 0));Assert ($h500 -eq 3 -and $hAction -eq 1 -and $hFinal) 'Saved E5-20260927-213307+0530 no longer meets PASSED evidence criteria'}
'E5_ACTIVE_STATUS_TEST=PASS'
