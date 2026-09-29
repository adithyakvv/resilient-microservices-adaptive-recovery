$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e2-postcleanup.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
$cleanup=[DateTimeOffset]::Parse('2026-09-28T22:30:28+05:30')
$stress=[pscustomobject]@{available=$true;podUid='inventory-uid';metricsTimestamp='2026-09-28T22:30:30+05:30';window='15s'}
$fresh=[pscustomobject]@{available=$true;podUid='inventory-uid';metricsTimestamp='2026-09-28T22:30:50+05:30';window='15s'}
Assert (-not (Test-E2PostCleanupSample -Sample $stress -CleanupVerifiedAt $cleanup).passed) 'A source window overlapping stress must not be published as post-cleanup'
Assert ((Test-E2PostCleanupSample -Sample $fresh -CleanupVerifiedAt $cleanup).passed) 'A wholly post-cleanup source window from the Ready pod must pass'
Assert (-not (Test-E2PostCleanupSample -Sample $null -CleanupVerifiedAt $cleanup).passed) 'Unavailable final sample must remain unavailable'
$published=[DateTimeOffset]::Parse('2026-09-28T22:30:51+05:30')
function Response([double]$at,[string]$value){[pscustomobject]@{status='success';data=[pscustomobject]@{result=@([pscustomobject]@{value=@($at,$value)})}}}
$before=$published.ToUnixTimeSeconds()
$after=$published.AddSeconds(15).ToUnixTimeSeconds()
Assert (-not (Test-E2PrometheusScrape -BytesResponse (Response $before '263946240') -RatioResponse (Response $before '0.491638') -PublishedAt $published -MemoryBytes 263946240 -MemoryRatio 0.491638).passed) 'Old repeated scrapes must not prove publication'
Assert (-not (Test-E2PrometheusScrape -BytesResponse (Response $after '394670080') -RatioResponse (Response $after '0.73513') -PublishedAt $published -MemoryBytes 263946240 -MemoryRatio 0.491638).passed) 'A scraped stress value must not be reported as restored memory'
Assert ((Test-E2PrometheusScrape -BytesResponse (Response $after '263946240') -RatioResponse (Response $after '0.491638') -PublishedAt $published -MemoryBytes 263946240 -MemoryRatio 0.491638).passed) 'A new scrape of the measured lower value must complete the graph'
$runner=Get-Content (Join-Path $PSScriptRoot 'run-e2-inventory-memory.ps1') -Raw
Assert ($runner.Contains('Complete-E2Cleanup -Run $run') -and $runner.Contains('Wait-E2PostCleanupGraph ([DateTimeOffset]::Parse($verifiedAt))')) 'Final capture must follow independent cleanup verification'
Assert ($runner.Contains("Read-Memory 'after' `$cleanupVerifiedAt") -and $runner.Contains('GRAPH_INCOMPLETE')) 'Missing final samples must not be fabricated or called complete'
Assert ($runner.Contains('if($null -ne $cleanupVerifiedAt)') -and -not $runner.Contains('$cleanupVerifiedAt.HasValue')) 'PowerShell unboxes nullable timestamp arguments; the final-source window guard must actually execute'
Assert ($runner.Contains('sourceTimestamp=$reading.metricsTimestamp') -and $runner.Contains('podUid=$reading.podUid')) 'Final source time and pod UID must be saved'
'E2_POSTCLEANUP_TESTS=PASS'
