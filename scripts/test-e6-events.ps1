$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e6-events.psm1') -Force
function Assert([bool]$ok,[string]$message){if(-not$ok){throw $message}}
function Metric([string]$value,[double]$sampleTime){
  [pscustomobject]@{status='success';data=[pscustomobject]@{result=@([pscustomobject]@{value=@($sampleTime,$value)})}}
}
$reset=[DateTimeOffset]::FromUnixTimeSeconds(1000)
Assert (Test-E6EventScrape (Metric '0' 1015) (Metric '1015' 1015) (Metric '0' 1015) (Metric '1015' 1015) 0 0 $reset) 'Fresh zero reset scrape was not accepted'
Assert (-not(Test-E6EventScrape (Metric '1' 999) (Metric '999' 999) (Metric '1' 999) (Metric '999' 999) 0 0 $reset)) 'Previous-run event values were accepted as this run'
Assert (-not(Test-E6EventScrape (Metric '0' 999) (Metric '999' 999) (Metric '0' 999) (Metric '999' 999) 0 0 $reset)) 'Old zero scrape was accepted as a new run reset'
Assert (Test-E6EventScrape (Metric '1' 1030) (Metric '1030' 1030) (Metric '1' 1030) (Metric '1030' 1030) 1 1 $reset) 'Confirmed events were not accepted'
Assert (-not(Test-E6EventScrape (Metric '1' 1030) (Metric '1030' 1030) (Metric '0' 1030) (Metric '1030' 1030) 1 1 $reset)) 'Missing healthy-replacement event was accepted'
Assert (-not(Test-E6EventScrape (Metric '1' 1030) (Metric '1030' 1030) (Metric '1' 1045) (Metric '1045' 1045) 1 1 $reset)) 'Different scrape times were accepted as one observation'
Assert (-not(Test-E6EventScrape (Metric 'NaN' 1030) (Metric '1030' 1030) (Metric '1' 1030) (Metric '1030' 1030) 1 1 $reset)) 'Unavailable event was accepted as observed'

$runner=Get-Content (Join-Path $PSScriptRoot 'run-e6-product-pod-kill.ps1') -Raw -Encoding UTF8
$check=$runner.IndexOf('if($CheckOnly){K @(')
$resetCall=$runner.IndexOf('$resetAt=Reset-E6Events')
$faultApply=$runner.IndexOf("K @('apply','-f',`$manifest)")
Assert ($check -ge 0 -and $resetCall -gt $check -and $faultApply -gt $resetCall) 'Run reset must follow CheckOnly and precede fault creation'
Assert ($runner.Contains('Wait-E6EventScrape 0 0 $resetAt')) 'Runner must confirm new-run zeros reached Prometheus'
Assert ($runner.Contains("event='product-interruption-observed'")) 'Observed interruption handoff missing'
Assert ($runner.Contains("event='healthy-replacement-verified'")) 'Healthy UID replacement handoff missing'
Assert ($runner.Contains('$run.timestamps.T1=$sampleAt') -and $runner.Contains('$run.timestamps.T4=IstNow')) 'Exact event timestamps must remain in the JSON report'
Assert ($runner.Contains('$run.timestamps.recoveryTime=Duration $run.timestamps.T1 $run.timestamps.T4')) 'Recovery duration must remain based on actual timestamps'
Assert ($runner.Contains('$run.telemetry.eventsScraped=Wait-E6EventScrape')) 'Runner must retain event values for a post-cleanup scrape'
'E6_EVENT_TESTS=PASS'
