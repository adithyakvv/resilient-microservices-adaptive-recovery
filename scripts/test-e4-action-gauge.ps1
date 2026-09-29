$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
Import-Module (Join-Path $PSScriptRoot 'e4-metrics.psm1') -Force
$published=[DateTimeOffset]::Parse('2026-09-29T00:21:46.000+05:30')
$fresh=$published.ToUnixTimeSeconds()+1
$stale=$published.ToUnixTimeSeconds()-1
function Response($value){[pscustomobject]@{status='success';data=[pscustomobject]@{result=@([pscustomobject]@{value=@(0,[string]$value)})}}}
Assert (Test-E4ScrapeMatch -ValueResponse (Response 0) -TimestampResponse (Response $fresh) -ExpectedVerified 0 -PublishedAt $published) 'New-run zero must be confirmed by a fresh scrape'
Assert (-not (Test-E4ScrapeMatch -ValueResponse (Response 1) -TimestampResponse (Response $fresh) -ExpectedVerified 0 -PublishedAt $published)) 'Retained prior-run one must not confirm a new-run zero'
Assert (-not (Test-E4ScrapeMatch -ValueResponse (Response 0) -TimestampResponse (Response $stale) -ExpectedVerified 0 -PublishedAt $published)) 'Stale zero must not confirm a new run'
Assert (Test-E4ScrapeMatch -ValueResponse (Response 1) -TimestampResponse (Response $fresh) -ExpectedVerified 1 -PublishedAt $published) 'Verified action one must have a fresh scrape'
Assert (-not (Test-E4ScrapeMatch -ValueResponse (Response 0) -TimestampResponse (Response $fresh) -ExpectedVerified 1 -PublishedAt $published)) 'Preview zero must not count as a verified action'
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e4-order-http500.ps1') -Raw
Assert ($runner.IndexOf('Publish-E4 $bp') -lt $runner.IndexOf('Set-Delay $true')) 'Baseline zero must publish before delay enable'
Assert ($runner.Contains('if($mitigationVerified -eq 0 -and $e4ZeroScrapePending)')) 'First new-run zero must await a real scrape'
Assert ($runner.Contains('if($pp.available){Publish-E4 $pp ([int]$report.action.actionVerified)}')) 'One must be published only from actual verified action and real probe'
Assert ($runner.Contains('Test-E4ScrapeMatch') -and $runner.Contains('AddSeconds(20)')) 'Gauge scrape confirmation must be bounded and checked'
'E4_ACTION_GAUGE_TEST=PASS'
