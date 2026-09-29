$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'e3-reporting.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}

$report=Get-Content (Join-Path $root 'reports/e3-order-inventory-delay-20260928-234207+0530.json') -Raw|ConvertFrom-Json
Assert ($report.runId -eq 'E3-20260928-234207+0530') 'Wrong diagnosis report'
Assert ($report.measurements[0].httpStatus -eq 503 -and -not $report.measurements[0].probeSuccess) 'Failed baseline probe evidence changed'
Assert (@($report.measurements|Where-Object {$_.phase -eq 'during' -and $_.probeSuccess -and $_.latencyMs -ge 1000}).Count -eq 3) 'Real during-delay probes not found'
Assert ($report.engineEvaluations[0].decision -eq 'CONTINUE' -and -not $report.engineEvaluations[0].execute) 'Historical Engine response changed'

$published=[DateTimeOffset]::Parse('2026-09-28T23:42:20.400+05:30')
$freshUnix=$published.ToUnixTimeMilliseconds()/1000.0+1
$staleUnix=$published.ToUnixTimeMilliseconds()/1000.0-1
function Response($value){[pscustomobject]@{status='success';data=[pscustomobject]@{result=@([pscustomobject]@{value=@(0,[string]$value)})}}}
Assert (Test-E3ScrapeMatch -ValueResponse (Response 1017.029) -TimestampResponse (Response $freshUnix) -ExpectedLatencyMs 1017.029 -PublishedAt $published) 'Fresh matching real sample should confirm'
Assert (-not (Test-E3ScrapeMatch -ValueResponse (Response 1017.029) -TimestampResponse (Response $staleUnix) -ExpectedLatencyMs 1017.029 -PublishedAt $published)) 'Old scrape must not confirm'
Assert (-not (Test-E3ScrapeMatch -ValueResponse (Response 16.087) -TimestampResponse (Response $freshUnix) -ExpectedLatencyMs 1017.029 -PublishedAt $published)) 'Overwritten after value must not confirm during sample'

$runner=Get-Content (Join-Path $PSScriptRoot 'run-e3-order-inventory-delay.ps1') -Raw
Assert ($runner.Contains('if($m.probeSuccess){') -and $runner.Contains('Not published as successful latency')) 'Failed probes must not update successful latency gauge'
Assert ($runner.IndexOf("Wait-E3PhaseScrape 'before'") -lt $runner.IndexOf('Set-Delay $true')) 'Baseline scrape must precede delay enable'
Assert ($runner.IndexOf("Wait-E3PhaseScrape 'during'") -lt $runner.LastIndexOf('Set-Delay $false')) 'During scrape must precede delay-off cleanup'
Assert ($runner.Contains("Wait-E3PhaseScrape 'after'")) 'Post-delay scrape verification missing'
Assert ($runner.Contains('Start-Sleep -Seconds 2') -and $runner.Contains('AddSeconds(20)')) 'Scrape wait must be bounded'

$dashboard=Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw|ConvertFrom-Json
$panel=@($dashboard.panels|Where-Object {$_.id -eq 103})
Assert ($panel.Count -eq 1 -and $panel[0].targets.Count -eq 1) 'E3 must have exactly one latency series'
Assert ($panel[0].targets[0].expr -eq 'adaptive_order_inventory_latency_ms{job="adaptive-recovery-engine-e3"}') 'E3 query must select the E3 exporter'
Assert ($panel[0].targets[0].legendFormat -eq 'Order to Inventory successful probe latency') 'E3 legend must identify safe successful probes'
Assert ($panel[0].fieldConfig.defaults.unit -eq 'ms') 'E3 latency must use milliseconds'
Assert (-not $panel[0].PSObject.Properties['timeFrom'] -and -not $panel[0].PSObject.Properties['timeTo']) 'E3 must follow Grafana time picker'
'E3_GRAFANA_VISIBILITY_TESTS=PASS'
