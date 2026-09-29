$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent
function Assert([bool]$ok,[string]$m){if(-not$ok){throw $m}}
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e5-order-http500.ps1') -Raw;$order=Get-Content (Join-Path $root 'adaptive-order-service/src/main/java/com/adaptive/order/E5FaultController.java') -Raw;$state=Get-Content (Join-Path $root 'adaptive-order-service/src/main/java/com/adaptive/order/E5FaultState.java') -Raw;$engine=Get-Content (Join-Path $root 'recovery-engine/src/main/java/com/adaptive/recovery/E5RecoveryService.java') -Raw;$controller=Get-Content (Join-Path $root 'recovery-engine/src/main/java/com/adaptive/recovery/RecoveryController.java') -Raw;$server=Get-Content (Join-Path $root 'gui/server.py') -Raw;$gui=Get-Content (Join-Path $root 'gui/index.html') -Raw;$dashRaw=Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw;$dash=$dashRaw|ConvertFrom-Json
Assert ($order.Contains('/api/internal/e5') -and $order.Contains('E5_ORDER_HTTP_500')) 'E5 dedicated route missing'
Assert ($state.Contains('AtomicBoolean') -and $state.Contains('false')) 'E5 must default disabled and be in-memory'
foreach($x in @('3','execute=false','execute=true','actionVerified','fresh','finally','Set-Fault $false','T4','T5','simulationOnly','no service was restarted')){Assert ($runner.Contains($x)) "E5 runner safeguard missing: $x"}
Assert (-not $runner.Contains('restartOrderPod') -and -not $runner.Contains('rollout restart')) 'E5 fallback must not restart Kubernetes'
Assert ($engine.Contains('persistence') -and $engine.Contains('SIMULATED_RESTART') -and $engine.Contains('no service was restarted')) 'E5 simulated policy missing'
Assert ($controller.Contains('adaptive_recovery_e5_http_500_consecutive') -and $controller.Contains('adaptive_recovery_e5_simulated_action')) 'E5 exporter count/action metrics missing'
Assert ($engine.Contains('fresh500') -and $engine.Contains('below simulated restart persistence threshold')) 'E5 fresh persistence gate missing'
Assert ($server.Contains('E5_SCRIPT') -and $server.Contains("'/api/e5/run'") -and $server.Contains("'/api/e5/status'")) 'E5 fixed GUI routes missing'
Assert ($server.Contains('e5_runtime_preflight') -and $server.Contains('/api/e5/sim-probe') -and $server.Contains('/api/e5/sim-fault') -and $server.Contains('E5 local fallback; no Order image required')) 'E5 fallback preflight missing'
Assert ($gui.Contains('E5 — HTTP 500 Application Fault') -and $gui.Contains('Fresh HTTP 500 count') -and $gui.Contains('e5PollTimer')) 'E5 GUI card/progress missing'
Assert ($gui.Contains("rt.status!=='READY'") -and $gui.Contains('Blocked —')) 'E5 GUI runtime block missing'
$p=$dash.panels|Where-Object id -eq 105;Assert ($p -and $p.title -eq 'E5 — HTTP 500 Application Fault') 'E5 Grafana panel title missing';Assert ($dashRaw.Contains('adaptive_recovery_e5_http_500_consecutive') -and $dashRaw.Contains('adaptive_recovery_e5_simulated_action') -and $dashRaw.Contains('vector(3)')) 'E5 Grafana queries missing'
$cases=@(@{n=0;decision='CONTINUE';restart=0},@{n=1;decision='OBSERVE';restart=0},@{n=2;decision='OBSERVE';restart=0},@{n=3;decision='SIMULATED_RESTART';restart=1});Assert ($cases[0].restart -eq 0 -and $cases[1].restart -eq 0 -and $cases[2].restart -eq 0 -and $cases[3].restart -eq 1) 'E5 persistence decision fixture failed'
'E5_PREPARATION_CHECK=PASS'
