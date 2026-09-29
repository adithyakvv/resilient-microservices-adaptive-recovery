function Test-E6EventScrape {
    param(
        [Parameter(Mandatory=$true)]$InterruptionValue,
        [Parameter(Mandatory=$true)]$InterruptionTimestamp,
        [Parameter(Mandatory=$true)]$ReplacementValue,
        [Parameter(Mandatory=$true)]$ReplacementTimestamp,
        [Parameter(Mandatory=$true)][ValidateSet(0,1)][int]$ExpectedInterruption,
        [Parameter(Mandatory=$true)][ValidateSet(0,1)][int]$ExpectedReplacement,
        [Parameter(Mandatory=$true)][DateTimeOffset]$PublishedAt
    )
    $responses = @($InterruptionValue,$InterruptionTimestamp,$ReplacementValue,$ReplacementTimestamp)
    foreach($response in $responses) {
        if($response.status -ne 'success' -or @($response.data.result).Count -ne 1 -or $null -eq $response.data.result[0]) { return $false }
    }
    $values = @()
    foreach($response in $responses) {
        $parsed = 0.0
        if(-not [double]::TryParse([string]$response.data.result[0].value[1],
                [Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)) { return $false }
        if([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed)) { return $false }
        $values += $parsed
    }
    $publishedSeconds = $PublishedAt.ToUnixTimeMilliseconds()/1000.0
    return ($values[0] -eq $ExpectedInterruption -and $values[2] -eq $ExpectedReplacement -and
        $values[1] -gt $publishedSeconds -and $values[3] -gt $publishedSeconds -and
        [math]::Abs($values[1]-$values[3]) -lt 0.001)
}
Export-ModuleMember -Function Test-E6EventScrape
