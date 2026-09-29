function Get-E2MemorySample {
  param(
    [Parameter(Mandatory)]$Metrics,
    [Parameter(Mandatory)]$Pods,
    [Parameter(Mandatory)][double]$LimitBytes,
    $PreviousSample,
    [DateTimeOffset]$ObservedAt = [DateTimeOffset]::UtcNow,
    [int]$MaxAgeSeconds = 45
  )
  $unavailable = { param($reason) [pscustomobject]@{ available = $false; reason = $reason } }
  if ($LimitBytes -le 0) { return & $unavailable 'Inventory memory limit is missing or invalid' }
  $ready = @($Pods.items | Where-Object {
    $_.metadata.name -like 'adaptive-inventory-service-*' -and
    -not $_.metadata.deletionTimestamp -and
    $_.status.phase -eq 'Running' -and
    @($_.status.containerStatuses | Where-Object { $_.name -eq 'adaptive-inventory-service' -and $_.ready -eq $true }).Count -eq 1
  })
  if ($ready.Count -ne 1) { return & $unavailable "Expected one Ready Inventory pod; found $($ready.Count)" }
  $pod = $ready[0]
  if (-not $pod.metadata.uid) { return & $unavailable 'Ready Inventory pod UID is unavailable' }
  $metric = @($Metrics.items | Where-Object { $_.metadata.name -eq $pod.metadata.name } | Select-Object -First 1)
  if (-not $metric) { return & $unavailable 'Metrics API has no sample for the Ready Inventory pod' }
  $container = @($metric.containers | Where-Object { $_.name -eq 'adaptive-inventory-service' } | Select-Object -First 1)
  if (-not $container) { return & $unavailable 'Metrics API has no Inventory container sample' }
  $sourceTime = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse([string]$metric.timestamp, [ref]$sourceTime)) { return & $unavailable 'PodMetrics timestamp is missing or invalid' }
  $age = ($ObservedAt - $sourceTime).TotalSeconds
  if ($age -gt $MaxAgeSeconds -or $age -lt -5) { return & $unavailable "PodMetrics timestamp is stale or in the future ($([math]::Round($age,1)) seconds from observation)" }
  $windowText = [string]$metric.window
  if ($windowText -notmatch '^(\d+(?:\.\d+)?)s$' -or [double]$Matches[1] -le 0) { return & $unavailable 'PodMetrics sampling window is missing or invalid' }
  if ($PreviousSample -and $PreviousSample.podUid -eq $pod.metadata.uid) {
    $previousTime = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$PreviousSample.metricsTimestamp, [ref]$previousTime) -and $sourceTime -le $previousTime) {
      return & $unavailable "Duplicate or older PodMetrics timestamp $($metric.timestamp) for the same Inventory pod"
    }
  }
  $raw = [string]$container.usage.memory
  if ($raw -notmatch '^(\d+(?:\.\d+)?)(Ki|Mi|Gi|k|M|G)?$') { return & $unavailable 'Inventory memory quantity is missing or invalid' }
  $number = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
  $factor = switch ($Matches[2]) { 'Ki' { 1024 } 'Mi' { 1MB } 'Gi' { 1GB } 'k' { 1000 } 'M' { 1000000 } 'G' { 1000000000 } default { 1 } }
  $bytes = $number * $factor
  if ($bytes -le 0 -or [double]::IsInfinity($bytes) -or [double]::IsNaN($bytes)) { return & $unavailable 'Inventory memory usage is missing or invalid' }
  [pscustomobject]@{
    available = $true; reason = $null
    timestamp = $ObservedAt.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:sszzz')
    metricsTimestamp = $sourceTime.ToString('o'); window = $windowText
    pod = [string]$pod.metadata.name; podUid = [string]$pod.metadata.uid
    container = 'adaptive-inventory-service'; memoryRatio = $bytes / $LimitBytes
    memoryBytes = $bytes; raw = $raw; limitBytes = $LimitBytes
  }
}

function Test-E2BaselineSamples {
  param([object[]]$Samples, [double]$GuardRatio = 0.55, [int]$Required = 3)
  if (@($Samples).Count -lt $Required) {
    $times = @($Samples | ForEach-Object { $_.metricsTimestamp } | Where-Object { $_ })
    $observed = if ($times.Count) { $times -join ', ' } else { 'none' }
    return [pscustomobject]@{ passed = $false; reason = "Only $(@($Samples).Count) of $Required distinct fresh baseline samples were available before timeout; source timestamps obtained: $observed" }
  }
  $first = $Samples[0]; $previous = [DateTimeOffset]::MinValue
  foreach ($sample in $Samples) {
    $sourceTime = [DateTimeOffset]::MinValue
    if (-not $sample.available -or -not $sample.podUid -or -not $sample.pod -or -not $sample.window -or
        -not [DateTimeOffset]::TryParse([string]$sample.metricsTimestamp, [ref]$sourceTime) -or
        $sample.podUid -ne $first.podUid -or $sample.pod -ne $first.pod -or $sourceTime -le $previous) {
      return [pscustomobject]@{ passed = $false; reason = 'Baseline samples are stale, duplicated, or from different Inventory pods' }
    }
    if ([double]$sample.memoryRatio -ge $GuardRatio) {
      return [pscustomobject]@{ passed = $false; reason = "Fresh baseline memory ratio $($sample.memoryRatio) is at or above guard $GuardRatio" }
    }
    $previous = $sourceTime
  }
  [pscustomobject]@{ passed = $true; reason = "$Required distinct fresh samples from the same Ready Inventory pod are below guard $GuardRatio" }
}

Export-ModuleMember -Function Get-E2MemorySample, Test-E2BaselineSamples
