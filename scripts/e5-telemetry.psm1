function Test-E5ScrapeMatch {
  param(
    [Parameter(Mandatory=$true)]$CountValue,
    [Parameter(Mandatory=$true)]$CountTimestamp,
    [Parameter(Mandatory=$true)]$ActionValue,
    [Parameter(Mandatory=$true)]$ActionTimestamp,
    [Parameter(Mandatory=$true)][int]$ExpectedCount,
    [Parameter(Mandatory=$true)][ValidateSet(0,1)][int]$ExpectedAction,
    [Parameter(Mandatory=$true)][DateTimeOffset]$PublishedAt
  )
  $responses=@($CountValue,$CountTimestamp,$ActionValue,$ActionTimestamp)
  foreach($response in $responses){if($response.status -ne 'success' -or @($response.data.result).Count -ne 1){return $false}}
  $actual=@()
  foreach($response in $responses){
    $parsed=0.0
    if(-not [double]::TryParse([string]$response.data.result[0].value[1],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){return $false}
    if([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed)){return $false}
    $actual+=$parsed
  }
  $publication=$PublishedAt.ToUnixTimeMilliseconds()/1000.0
  return ($actual[0] -eq $ExpectedCount -and $actual[2] -eq $ExpectedAction -and
    $actual[1] -gt $publication -and $actual[3] -gt $publication -and
    [math]::Abs($actual[1]-$actual[3]) -lt 0.001)
}
Export-ModuleMember -Function Test-E5ScrapeMatch
