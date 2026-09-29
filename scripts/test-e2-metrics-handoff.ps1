$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$m){if(-not$ok){throw $m}}
$c=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'recovery-engine/src/main/java/com/adaptive/recovery/RecoveryController.java') -Raw
$y=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'infrastructure/monitoring/prometheus/e2-engine-scrape-secret.yaml') -Raw
Assert ($c.Contains('/e2/metrics') -and $c.Contains('/e2/sample') -and $c.Contains('/e1/sample') -and $c.Contains('adaptive_recovery_e1_cpu_cores') -and $c.Contains('adaptive_recovery_e2_memory_ratio') -and $c.Contains('adaptive_recovery_e2_memory_bytes') -and $c.Contains('action_verified') -and $c.Contains('verified_actions_total') -and $c.Contains('incrementAndGet')) 'Experiment exporter metrics missing'
$runner=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/run-e2-inventory-memory.ps1') -Raw;Assert ($runner.Contains('/api/recovery/e2/sample') -and $runner.Contains('Publish-E2Sample') -and $runner.Contains("Read-Memory 'after'")) 'E2 runner sample publication/final sample missing'
Assert ($y.Contains('host.docker.internal:8090') -and $y.Contains('source: recovery-engine')) 'Local Engine scrape path missing'
Assert (-not $c.Contains('{runId=') -and -not $c.Contains('{timestamp=')) 'E2 exported Prometheus samples must not use run IDs or timestamps as labels'
'E2_METRICS_HANDOFF_TESTS=PASS'
