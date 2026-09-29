function Get-E3Median {
  param([Parameter(Mandatory=$true)][AllowEmptyCollection()][double[]]$Values)
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $ordered = @($Values | Sort-Object)
  $middle = [int][Math]::Floor($ordered.Count / 2.0)
  if ($ordered.Count % 2 -eq 1) { return [double]$ordered[$middle] }
  return [Math]::Round((([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2.0), 3)
}

function Set-E3ObservedTimestamp {
  param(
    [Parameter(Mandatory=$true)]$Run,
    [Parameter(Mandatory=$true)][ValidateSet('T0','T1','T2','T3','T4','T5')][string]$Event,
    [Parameter(Mandatory=$true)][string]$Timestamp,
    [Parameter(Mandatory=$true)][string]$Evidence
  )
  if (-not $Run.timestamps) { $Run['timestamps'] = [ordered]@{} }
  if (-not $Run.timestampEvidence) { $Run['timestampEvidence'] = [ordered]@{} }
  if ($Run.timestamps[$Event]) { return $false }
  # Parse for validity, but preserve the exact observed timestamp string.
  [void][DateTimeOffset]::Parse($Timestamp)
  $Run.timestamps[$Event] = $Timestamp
  $Run.timestampEvidence[$Event] = $Evidence
  return $true
}

function Test-E3ScrapeMatch {
  param(
    [Parameter(Mandatory=$true)]$ValueResponse,
    [Parameter(Mandatory=$true)]$TimestampResponse,
    [Parameter(Mandatory=$true)][double]$ExpectedLatencyMs,
    [Parameter(Mandatory=$true)][DateTimeOffset]$PublishedAt
  )
  if ($ValueResponse.status -ne 'success' -or $TimestampResponse.status -ne 'success') { return $false }
  $values = @($ValueResponse.data.result)
  $timestamps = @($TimestampResponse.data.result)
  if ($values.Count -ne 1 -or $timestamps.Count -ne 1) { return $false }
  $actual = 0.0
  $scrapedAt = 0.0
  $culture = [Globalization.CultureInfo]::InvariantCulture
  if (-not [double]::TryParse([string]$values[0].value[1], [Globalization.NumberStyles]::Float, $culture, [ref]$actual)) { return $false }
  if (-not [double]::TryParse([string]$timestamps[0].value[1], [Globalization.NumberStyles]::Float, $culture, [ref]$scrapedAt)) { return $false }
  if ([double]::IsNaN($actual) -or [double]::IsInfinity($actual) -or [double]::IsNaN($scrapedAt)) { return $false }
  $publicationUnix = $PublishedAt.ToUnixTimeMilliseconds() / 1000.0
  return ($scrapedAt -gt $publicationUnix -and [math]::Abs($actual - $ExpectedLatencyMs) -le 0.001)
}

Export-ModuleMember -Function Get-E3Median, Set-E3ObservedTimestamp, Test-E3ScrapeMatch
