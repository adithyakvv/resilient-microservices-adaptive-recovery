$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$message){if(-not$ok){throw $message}}
$html=Get-Content (Join-Path (Split-Path $PSScriptRoot -Parent) 'gui/index.html') -Raw
foreach($required in @('wasOpen=!!disclosure?.open','replacement.open=true',"timeZone:'Asia/Kolkata'",'Data quality:','Latest OBSERVE is a later cooldown evaluation','resourceFields(','timestampLabel','clearInterval(e1PollTimer)','setInterval(async()=>{await metrics();await loadDecision()},15000)')){if($html.IndexOf($required,[System.StringComparison]::Ordinal) -lt 0){throw "GUI E1 assertion missing: $required"}}
$e1Section=[regex]::Match($html,'(?s)<section[^>]+id="e1-panel".*?</section>').Value
if($e1Section.Contains('T4')){throw 'E1 GUI must not render or require T4'}
foreach($required in @("s.report||s.running||!document.querySelector('#e1-report .e1-box')",'No E1 run report yet.','reportHtml(s)','e1PollTimer=null')){if($html.IndexOf($required,[System.StringComparison]::Ordinal) -lt 0){throw "GUI terminal-report assertion missing: $required"}}
Assert ($html.Contains("if(s.error){document.getElementById('e1-status').innerHTML")) 'Final status errors must be visible'
Assert ($html.Contains("if(s.report||s.running||!document.querySelector('#e1-report .e1-box'))")) 'A failed final fetch must preserve the existing report DOM'
Assert ($html.Contains('load();setInterval(async()=>{await metrics();await loadDecision()},15000)')) 'Refresh must retain saved report loading through initial load'
'E1_GUI_DISCLOSURE_AND_REPORT_ASSERTIONS=PASS'
