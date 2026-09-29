$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e4-order-http500.ps1') -Raw
$gui=Get-Content (Join-Path $root 'gui/index.html') -Raw
$server=Get-Content (Join-Path $root 'gui/server.py') -Raw
$dashRaw=Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw; $dash=$dashRaw | ConvertFrom-Json
if(-not $runner.Contains('/api/internal/e3-delay') -or -not $runner.Contains('/api/recovery/e4/evaluate') -or -not $runner.Contains('latencyMs') -or -not $runner.Contains('finally')){throw 'E4 runner safeguards missing'}
if(-not $runner.Contains('execute=false') -or -not $runner.Contains('actionVerified') -or -not $runner.Contains('faultOff')){throw 'E4 persistence/action/cleanup evidence missing'}
if(-not $runner.Contains('Invoke-Preflight') -or -not $runner.Contains("status='Blocked'") -or -not $runner.Contains('enabled=false') -or -not $runner.Contains('delayMs=0')){throw 'E4 preflight gate/reset missing'}
if(-not $runner.Contains("`$report.result='BLOCKED'") -or -not $runner.Contains('if($report.fault.enabled)')){throw 'E4 blocked path must not inject or perform fault cleanup'}
foreach($needle in @('Order is not 1/1 Ready','health endpoint is not UP','did not confirm enabled=false and delayMs=0','start-demo-gui.ps1','rollout status deployment/adaptive-order-service')){if(-not $runner.Contains($needle)){throw "E4 preflight blocked-case evidence missing: $needle"}}
if(-not $runner.Contains('mitigationVerified') -or -not $runner.Contains('Hold-ForPrometheusScrape')){throw 'E4 mitigation or scrape-history safeguards missing'}
if(-not $runner.Contains('Add-Member -NotePropertyName engineActionVerified') -or -not $runner.Contains('Disable-DelayVerified')){throw 'E4 action/cleanup verification must tolerate response/property and connection failures'}
if(-not $runner.Contains('available=($before -ne $null -and $after -ne $null)') -or -not $runner.Contains('if($pp.available){Publish-E4')){throw 'E4 unavailable post-mitigation probe must be recorded without aborting finalization'}
if(-not $runner.Contains('Ensure-OrderForward') -or -not $runner.Contains('portforward-pids')){throw 'E4 must recover and hand off a dropped Order port-forward'}
if(-not $runner.Contains('SIMULATED_DELAY_MITIGATION') -or -not $runner.Contains('two fresh')){throw 'E4 must use deterministic simulated-delay mitigation'}
if(-not $gui.Contains('Experiment E4') -or -not $gui.Contains('runE4()') -or -not $gui.Contains('latency')){throw 'E4 GUI card missing'}
if(-not $server.Contains("'/api/e4/run'") -or -not $server.Contains("'/api/e4/status'")){throw 'E4 fixed server routes missing'}
if(-not $server.Contains("report.get('result') != 'CHECK_ONLY_PASS'")){throw 'E4 latest report selection must retain blocked non-check-only reports'}
if(-not $gui.Contains('Preflight') -or -not $gui.Contains('Restore/check with')){throw 'E4 blocked preflight message missing'}
$p=$dash.panels | Where-Object {$_.id -eq 104}; if(-not $p -or $p.title -notlike '*Simulated-delay mitigation*' -or $p.type -ne 'timeseries'){throw 'E4 dashboard panel invalid'}
if(-not $dashRaw.Contains('adaptive_recovery_e4_order_inventory_latency_ms') -or -not $dashRaw.Contains('adaptive_recovery_e4_mitigation_verified')){throw 'E4 latency/mitigation queries missing'}
'E4_PREPARATION_CHECK=PASS'
