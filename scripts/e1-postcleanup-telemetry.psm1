function Test-E1PostCleanupSample {
  param($Reading, [string]$CleanupCompletedAt, [string]$LastStressSourceTimestamp,
        [string]$CurrentPodName, [string]$CurrentPodUid)
  if (-not $Reading -or -not $Reading.sourceTimestamp -or -not $Reading.window) {
    return @{ passed=$false; reason='Metrics API source timestamp or window unavailable' }
  }
  if ($Reading.pod -ne $CurrentPodName -or -not $CurrentPodUid) {
    return @{ passed=$false; reason='sample is not from the current Ready Inventory pod' }
  }
  $source=[DateTimeOffset]::MinValue; $cleanup=[DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse([string]$Reading.sourceTimestamp,[ref]$source) -or
      -not [DateTimeOffset]::TryParse($CleanupCompletedAt,[ref]$cleanup) -or
      [string]$Reading.window -notmatch '^([0-9]+(?:\.[0-9]+)?)s$') {
    return @{ passed=$false; reason='invalid Metrics API timestamp or sampling window' }
  }
  $seconds=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
  if ($seconds -le 0) { return @{ passed=$false; reason='invalid Metrics API sampling window' } }
  $windowStart=$source.AddSeconds(-$seconds)
  if ($source -le $cleanup -or $windowStart -le $cleanup) {
    return @{ passed=$false; reason='Metrics API window overlaps cleanup or stress period'; windowStart=$windowStart.ToString('o') }
  }
  if ($LastStressSourceTimestamp) {
    $last=[DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($LastStressSourceTimestamp,[ref]$last) -and $source -le $last) {
      return @{ passed=$false; reason='Metrics API source timestamp is not newer than last stress sample' }
    }
  }
  if ($null -eq $Reading.cpuCores -or [double]::IsNaN([double]$Reading.cpuCores) -or
      [double]::IsInfinity([double]$Reading.cpuCores) -or [double]$Reading.cpuCores -lt 0) {
    return @{ passed=$false; reason='CPU reading unavailable or invalid' }
  }
  return @{ passed=$true; reason='fresh post-cleanup Metrics API window'; windowStart=$windowStart.ToString('o') }
}
Export-ModuleMember -Function Test-E1PostCleanupSample
