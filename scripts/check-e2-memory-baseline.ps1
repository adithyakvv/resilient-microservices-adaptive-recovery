param(
  [int]$SamplesRequired = 3,
  [int]$TimeoutSeconds = 65,
  [int]$PollSeconds = 5
)
$ErrorActionPreference = 'Stop'
$kubectl = if ($env:KUBECTL_BIN) { $env:KUBECTL_BIN } else { (Get-Command kubectl -ErrorAction Stop).Source }
$namespace = 'resilient-microservices-adaptive-recovery'
Import-Module (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Force

function KJson([string[]]$Arguments) {
  $text = (& $kubectl --context docker-desktop --namespace $namespace @Arguments | Out-String)
  if ($LASTEXITCODE -ne 0) { throw "kubectl read failed: $($Arguments -join ' ')" }
  return $text | ConvertFrom-Json
}

try {
  if (-not (Test-Path $kubectl)) { throw "Docker Desktop kubectl.exe missing: $kubectl" }
  $status = Invoke-RestMethod 'http://127.0.0.1:18080/api/e2/status' -TimeoutSec 5
  if ($status.running -or $status.activeExperiment) { throw 'Another experiment is active; E2 preflight stopped' }
  $chaos = & $kubectl --context docker-desktop --namespace $namespace get stresschaos adaptive-inventory-e2-memory --ignore-not-found -o name
  if ($LASTEXITCODE -ne 0 -or $chaos) { throw 'E2 Chaos absence could not be verified' }
  $deployment = KJson @('get','deployment','adaptive-inventory-service','-o','json')
  $container = @($deployment.spec.template.spec.containers | Where-Object name -eq 'adaptive-inventory-service' | Select-Object -First 1)
  if ($deployment.spec.replicas -ne 1 -or $deployment.status.readyReplicas -ne 1 -or
      $container.resources.requests.cpu -ne '100m' -or $container.resources.limits.cpu -ne '500m' -or
      $container.resources.requests.memory -ne '256Mi' -or $container.resources.limits.memory -ne '512Mi') {
    throw 'Inventory is not 1/1 Ready at the exact 100m/500m CPU, 256Mi/512Mi memory baseline'
  }
  $samples = @(); $previous = $null
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
  while ($samples.Count -lt $SamplesRequired -and [DateTimeOffset]::UtcNow -lt $deadline) {
    $metrics = KJson @('get','--raw',"/apis/metrics.k8s.io/v1beta1/namespaces/$namespace/pods")
    $pods = KJson @('get','pods','-l','app.kubernetes.io/name=adaptive-inventory-service','-o','json')
    $sample = Get-E2MemorySample -Metrics $metrics -Pods $pods -LimitBytes (512MB) -PreviousSample $previous
    if ($sample.available) {
      $samples += $sample; $previous = $sample
      "SAMPLE=$($samples.Count) source=$($sample.metricsTimestamp) window=$($sample.window) pod=$($sample.pod) uid=$($sample.podUid) memory=$($sample.raw) ratio=$([math]::Round($sample.memoryRatio,6))"
    } else { "WAITING_FOR_FRESH_SAMPLE=$($sample.reason)" }
    if ($samples.Count -lt $SamplesRequired) { Start-Sleep -Seconds $PollSeconds }
  }
  $assessment = Test-E2BaselineSamples -Samples $samples -GuardRatio 0.55 -Required $SamplesRequired
  if ($assessment.passed) { "E2_PREFLIGHT=PASS -- $($assessment.reason)"; exit 0 }
  "E2_PREFLIGHT=BLOCKED -- $($assessment.reason)"; exit 2
} catch {
  "E2_PREFLIGHT=BLOCKED -- $($_.Exception.Message)"
  exit 2
}
