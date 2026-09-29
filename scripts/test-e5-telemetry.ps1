$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'e5-telemetry.psm1') -Force

function Assert([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Metric([double]$value, [double]$scrapedAt) {
    return [pscustomobject]@{
        status = 'success'
        data = [pscustomobject]@{
            result = @([pscustomobject]@{ value = @($scrapedAt, $value.ToString([Globalization.CultureInfo]::InvariantCulture)) })
        }
    }
}

$published = [DateTimeOffset]::FromUnixTimeSeconds(1000)
foreach ($count in 0..3) {
    $action = if ($count -eq 3) { 1 } else { 0 }
    Assert (Test-E5ScrapeMatch (Metric $count 1015) (Metric 1015 1015) (Metric $action 1015) (Metric 1015 1015) $count $action $published) "Fresh count/action scrape $count failed"
}
Assert (-not (Test-E5ScrapeMatch (Metric 3 999) (Metric 999 999) (Metric 1 999) (Metric 999 999) 3 1 $published)) 'A previous-run scrape was accepted'
Assert (-not (Test-E5ScrapeMatch (Metric 2 1015) (Metric 1015 1015) (Metric 0 1015) (Metric 1015 1015) 3 0 $published)) 'Wrong persistence count was accepted'
Assert (-not (Test-E5ScrapeMatch (Metric 3 1015) (Metric 1015 1015) (Metric 0 1015) (Metric 1015 1015) 3 1 $published)) 'An unrecorded action was accepted'
Assert (-not (Test-E5ScrapeMatch (Metric 3 1015) (Metric 1015 1015) (Metric 1 1016) (Metric 1016 1016) 3 1 $published)) 'Mismatched scrape times were accepted'

$runner = Get-Content (Join-Path $PSScriptRoot 'run-e5-order-http500.ps1') -Raw
Assert ($runner.Contains('/api/recovery/e5/start')) 'Runner does not reset E5 state for each run'
Assert ($runner.Contains('Wait-E5Scrape 0 0')) 'Runner does not confirm a reset baseline scrape'
Assert ($runner.Contains('Wait-E5Scrape $freshCount 0')) 'Runner does not hold each fresh count for a scrape'
Assert ($runner.Contains('Wait-E5Scrape 3 1')) 'Runner does not confirm recorded-action scrape'
Assert ($runner.Contains('Wait-E5Scrape 0 ([int]$acted)')) 'Runner does not publish a real final healthy count'
Assert ($runner.Contains('Set-Fault $false')) 'Runner must disable the fault in finally'
Assert (-not $runner.Contains('rollout restart')) 'E5 must not restart Kubernetes'
'E5_TELEMETRY_TEST=PASS'
