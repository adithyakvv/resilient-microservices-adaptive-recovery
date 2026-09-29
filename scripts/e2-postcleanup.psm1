function Test-E2PostCleanupSample {
  param($Sample, [DateTimeOffset]$CleanupVerifiedAt)
  if (-not $Sample -or -not $Sample.available -or -not $Sample.podUid) {
    return [pscustomobject]@{passed=$false;reason='No sample from a Ready Inventory pod'}
  }
  $source=[DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse([string]$Sample.metricsTimestamp,[ref]$source)) {
    return [pscustomobject]@{passed=$false;reason='Metrics API source timestamp is unavailable'}
  }
  if ([string]$Sample.window -notmatch '^(\d+(?:\.\d+)?)s$') {
    return [pscustomobject]@{passed=$false;reason='Metrics API sampling window is unavailable'}
  }
  $windowSeconds=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
  if ($windowSeconds -le 0 -or $source.AddSeconds(-$windowSeconds) -le $CleanupVerifiedAt) {
    return [pscustomobject]@{passed=$false;reason='Metrics API window has not moved fully past verified cleanup'}
  }
  return [pscustomobject]@{passed=$true;reason='Fresh Ready-pod Metrics API window is wholly after verified cleanup'}
}

function Test-E2PrometheusScrape {
  param($BytesResponse,$RatioResponse,[DateTimeOffset]$PublishedAt,[double]$MemoryBytes,[double]$MemoryRatio)
  if (-not $BytesResponse -or -not $RatioResponse -or $BytesResponse.status -ne 'success' -or $RatioResponse.status -ne 'success') {
    return [pscustomobject]@{passed=$false;reason='Prometheus query failed';scrapedAt=$null}
  }
  $bytes=@($BytesResponse.data.result);$ratio=@($RatioResponse.data.result)
  if ($bytes.Count -ne 1 -or $ratio.Count -ne 1) {
    return [pscustomobject]@{passed=$false;reason='E2 gauge series is missing or ambiguous';scrapedAt=$null}
  }
  $bv=@($bytes[0].value);$rv=@($ratio[0].value)
  if ($bv.Count -ne 2 -or $rv.Count -ne 2) {
    return [pscustomobject]@{passed=$false;reason='Prometheus gauge sample is unavailable';scrapedAt=$null}
  }
  $bt=[DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$bv[0]*1000))
  $rt=[DateTimeOffset]::FromUnixTimeMilliseconds([long]([double]$rv[0]*1000))
  if ($bt -le $PublishedAt -or $rt -le $PublishedAt) {
    return [pscustomobject]@{passed=$false;reason='Prometheus has not scraped the published sample yet';scrapedAt=$null}
  }
  $b=0.0;$r=0.0
  if (-not [double]::TryParse([string]$bv[1],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$b) -or
      -not [double]::TryParse([string]$rv[1],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$r) -or
      [math]::Abs($b-$MemoryBytes) -gt 0.5 -or [math]::Abs($r-$MemoryRatio) -gt 0.000001) {
    return [pscustomobject]@{passed=$false;reason='Prometheus latest gauge does not match the fresh Metrics API reading';scrapedAt=$null}
  }
  return [pscustomobject]@{passed=$true;reason='Both E2 gauges were scraped after publication with the measured values';scrapedAt=$bt.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:sszzz')}
}

Export-ModuleMember -Function Test-E2PostCleanupSample,Test-E2PrometheusScrape
