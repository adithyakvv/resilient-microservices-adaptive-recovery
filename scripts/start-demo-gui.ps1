$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$kubectl=if($env:KUBECTL_BIN){$env:KUBECTL_BIN}else{(Get-Command kubectl -ErrorAction Stop).Source}
if(-not(Test-Path -LiteralPath $kubectl)){throw "kubectl executable not found: $kubectl"}
$ns='resilient-microservices-adaptive-recovery'
$module=Join-Path $PSScriptRoot 'e1-preflight.psm1'
Import-Module $module -Force

$map=@(@('adaptive-product-service','18081:8081'),@('adaptive-inventory-service','18082:8082'),@('adaptive-order-service','18083:8083'),@('adaptive-recovery-prometheus','19090:9090'),@('adaptive-recovery-grafana','13000:3000'))
$jobs=@()
foreach($m in $map){$jobs+=Start-Process $kubectl -ArgumentList '-n',$ns,'port-forward',('svc/'+$m[0]),$m[1] -PassThru -WindowStyle Hidden}
$jobs | ForEach-Object {$_.Id} | Set-Content (Join-Path $root 'gui\.portforward-pids')

$py=(Get-Command python -ErrorAction SilentlyContinue).Source
if(-not $py){throw 'Python is required'}
$env:KUBECTL_BIN=$kubectl
$env:PROMETHEUS_URL='http://127.0.0.1:19090'
$env:RECOVERY_ENGINE_PORT='8090'
$env:KUBERNETES_NAMESPACE=$ns
$jar=Join-Path $root 'recovery-engine\target\recovery-engine-0.1.0-SNAPSHOT.jar'
if(-not(Test-Path -LiteralPath $jar)){throw "Recovery Engine JAR not found. Build it with Maven first: $jar"}
$prometheusReady=$false
for($i=0;$i -lt 30;$i++){
  try{$response=Invoke-WebRequest 'http://127.0.0.1:19090/-/ready' -TimeoutSec 2;if($response.StatusCode -eq 200){$prometheusReady=$true;break}}catch{}
  Start-Sleep -Seconds 1
}
if(-not $prometheusReady){throw 'Project Prometheus did not become reachable on 127.0.0.1:19090; Engine startup was not attempted.'}
$engine=Start-Process java -ArgumentList '-jar',$jar -PassThru -WindowStyle Hidden
$engine.Id | Set-Content (Join-Path $root 'gui\.engine-pid')

try {
  $health=$null
  for($i=0;$i -lt 30;$i++){
    try{$health=Invoke-RestMethod 'http://127.0.0.1:8090/actuator/health' -TimeoutSec 2;if($health.status -eq 'UP'){break}}catch{}
    Start-Sleep -Seconds 1
  }
  if(-not $health -or $health.status -ne 'UP'){throw 'Recovery Engine health did not become UP on port 8090.'}
  $engineProcess=Get-CimInstance Win32_Process -Filter "ProcessId = $($engine.Id)" -ErrorAction Stop
  if(-not $engineProcess -or -not $engineProcess.CommandLine.Contains($jar)){throw "Port 8090 did not verify as the Engine process launched from $jar; stop the demo and retry."}
  $engineListeners=@(Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $engine.Id)
  if(-not $engineListeners){throw "Port 8090 is not owned by the Recovery Engine process started by this script (PID $($engine.Id)). Stop the demo before retrying."}

  # A read-only evaluation verifies the actual Metrics API, Prometheus,
  # readiness, and dependency signals with the configured kubectl path.
  $live=Invoke-RestMethod 'http://127.0.0.1:8090/api/recovery/evaluate/adaptive-inventory-service?execute=false' -Method Post -TimeoutSec 20
  $preflight=Test-E1EnginePreflight -Response $live -RequiredPersistenceSamples 3 -MaximumAgeSeconds 30
  if(-not $preflight.passed){throw ('Recovery Engine is healthy but E1 signals are not ready: '+($preflight.blockers -join '; ')+$(if($live.reason){'; Engine reason: '+$live.reason}else{''}))}
  Write-Host ("Recovery Engine verified with kubectl: {0}" -f $kubectl)
  Write-Host ("E1 signal preflight: PASS; CPU={0} cores, memory ratio={1}, readiness={2}, Kubernetes healthy={3}, dependency up={4}, persistence samples={5}." -f $live.signals.cpu,$live.signals.memory,$live.signals.readiness,$live.signals.kubernetesHealthy,$live.signals.dependencyUp,$live.signals.persistenceSamples)
} catch {
  Stop-Process -Id $engine.Id -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $root 'gui\.engine-pid') -Force -ErrorAction SilentlyContinue
  throw
}

$gui=Start-Process $py -ArgumentList (Join-Path $root 'gui\server.py') -PassThru -WindowStyle Hidden
$gui.Id | Set-Content (Join-Path $root 'gui\.gui-pid')
Start-Sleep 3
Start-Process 'http://127.0.0.1:18080'
Write-Host 'Demo GUI: http://127.0.0.1:18080'
