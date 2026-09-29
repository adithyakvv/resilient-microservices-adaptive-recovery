$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$m){if(-not$ok){throw $m}}
$html=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'gui/index.html') -Raw
foreach($x in @('compactExperiment','data-report-details','Full ${kind} report','Prepared — not run','current.querySelector')){Assert ($html.Contains($x)) "Compact GUI assertion missing: $x"}
Assert ($html.Contains("current.open=true")) 'Running details must remain expanded'
Assert ($html.Contains("if(cpuOpen&&nested)nested.open=true")) 'Nested reading disclosure state must be preserved'
Assert ($html.Contains("/api/e1/status") -and $html.Contains("/api/e2/status")) 'E1/E2 saved reports must load independently'
Assert ($html.Contains("e2Report(s)") -and $html.Contains("Timestamps (IST)") -and $html.Contains("Engine evaluations") -and $html.Contains("Chaos / health") -and $html.Contains("Memory readings")) 'Partial running E2 report must render all progress sections'
Assert ($html.Contains('Recommendation — not applied') -and $html.Contains('e2-preview') -and $html.Contains('Applied and verified')) 'E2 evaluation outcome styling missing'
$server=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'gui/server.py') -Raw
Assert ($server.Contains("REPORTS / 'e2-progress.json'") -and $server.Contains('latest_e2_report')) 'E2 status must expose active progress and final report'
'E2_PARTIAL_PROGRESS_RENDER_TEST=PASS'
'E2_GUI_COMPACT_TESTS=PASS'
