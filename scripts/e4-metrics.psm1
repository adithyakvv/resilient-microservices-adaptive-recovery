function Test-E4ScrapeMatch {
  param(
    [Parameter(Mandatory=$true)]$ValueResponse,
    [Parameter(Mandatory=$true)]$TimestampResponse,
    [Parameter(Mandatory=$true)][ValidateSet(0,1)][int]$ExpectedVerified,
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
  if ([double]::IsNaN($actual) -or [double]::IsNaN($scrapedAt)) { return $false }
  return ($actual -eq $ExpectedVerified -and $scrapedAt -gt ($PublishedAt.ToUnixTimeMilliseconds()/1000.0))
}

Export-ModuleMember -Function Test-E4ScrapeMatch
