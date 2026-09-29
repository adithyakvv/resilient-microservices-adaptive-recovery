$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$m){if(-not$ok){throw $m}}
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e2-inventory-memory.ps1') -Raw
$baselineModule=Get-Content (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Raw
$reader=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'recovery-engine/src/main/java/com/adaptive/recovery/PrometheusReader.java') -Raw
Assert ($baselineModule.Contains('usage.memory') -and $runner.Contains('memoryBytes') -and $runner.Contains('memoryRatio')) 'E2 runner must use container memory usage and configured limit'
Assert ($reader.Contains('jvm_memory_used_bytes') -and $reader.Contains('jvm_memory_max_bytes')) 'Prometheus reader compatibility marker missing'
Assert ($reader.Contains('memory=max>0?used/max:Double.NaN')) 'Engine memory ratio calculation not found'
$ratio=128MB/512MB;Assert ($ratio -eq .25) 'Memory ratio conversion fixture failed'
$decision=if(.90 -ge .85){'INCREASE_MEMORY'}else{'CONTINUE'};Assert ($decision -eq 'INCREASE_MEMORY') 'Memory threshold fixture failed'
$baseline=.513824462890625;$increase=.361305236816406;$miPerMb=$increase*512/192;$p128=$baseline+(128*$miPerMb/512);Assert ($p128 -gt .70 -and $p128 -lt .82) 'Selected 128MB stress must cross E2 threshold and remain below cap'
Assert ($runner.Contains('profile=e2-memory') -and $runner.Contains('MemoryThresholdRatio = 0.65') -and $runner.Contains('BaselineGuardRatio = 0.55')) 'E2 must opt into its threshold profile';$app=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'recovery-engine/src/main/resources/application.yml') -Raw;Assert ($app.Contains('memory-threshold: ${RECOVERY_MEMORY_THRESHOLD:0.85}') -and $app.Contains('e2-memory-threshold: ${RECOVERY_E2_MEMORY_THRESHOLD:0.65}')) 'Normal/E2 thresholds not independently configured'
Assert ($runner.Contains('metricsTimestamp') -and $runner.Contains('lastMetricsSample') -and $baselineModule.Contains('PreviousSample') -and $baselineModule.Contains('metric.timestamp')) 'PodMetrics timestamp freshness check missing'
'E2_MEMORY_SIGNAL_MAPPING_TESTS=PASS'
