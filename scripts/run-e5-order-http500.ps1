param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent;$reports=Join-Path $root 'reports';New-Item $reports -ItemType Directory -Force|Out-Null
$Namespace='resilient-microservices-adaptive-recovery';$Sim='http://127.0.0.1:18080';$Engine='http://127.0.0.1:8090'
$runId='E5-'+(Get-Date).ToString('yyyyMMdd-HHmmsszzz').Replace(':','');$path=Join-Path $reports "e5-order-http500-$runId.json";$progress=Join-Path $reports 'e5-progress.json';$lastTimestamp=$null;$acted=$false
$run=[ordered]@{experiment='E5';runId=$runId;checkOnly=$CheckOnly;simulationOnly=$true;runStatus='Running';result=$null;experimentOutcome=$null;thresholdHttp500=3;persistenceSamplesRequired=3;timezone='Asia/Kolkata (+05:30)';timestamps=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T4=$null;T5=$null};timestampDefinitions=[ordered]@{T0='Fault enabled';T1='First HTTP 500 observed';T2='Engine observing/decision';T3='Simulated restart action recorded';T4='Healthy HTTP 200 confirmed';T5='Fault disabled and cleanup verified'};timestampEvidence=[ordered]@{};events=@();fault=[ordered]@{enabled=$false};baseline=[ordered]@{podUid=$null;ready=$null;health=$null};after=[ordered]@{podUid=$null;ready=$null;health=$null;routeStatus=$null};samples=@();engineEvaluations=@();cleanup=[ordered]@{status=$null;faultOff=$false;ready=$null;health=$null;routeRecovered=$false;simulation='No Kubernetes service was restarted'}}
$run['telemetry']=[ordered]@{scrapes=@();graphComplete=$null;error=$null}
Import-Module (Join-Path $PSScriptRoot 'e5-telemetry.psm1') -Force
function Save{$j=$run|ConvertTo-Json -Depth 20;$j|Set-Content $path -Encoding UTF8;$j|Set-Content $progress -Encoding UTF8}
function KJson([string[]]$a){$k=$env:KUBECTL_BIN;if(-not$k){$k=(Get-Command kubectl -ErrorAction Stop).Source};$o=&$k @a 2>$null;if($LASTEXITCODE-ne 0){return $null};try{$o|ConvertFrom-Json}catch{$null}}
function Order-Snapshot{$x=KJson @('-n',$Namespace,'get','pods','-l','app.kubernetes.io/name=adaptive-order-service','-o','json');if(-not$x){return $null};$p=$x.items|Where-Object {$_.status.containerStatuses[0].ready}|Select-Object -First 1;if(-not$p){return $null};[pscustomobject]@{uid=$p.metadata.uid;name=$p.metadata.name;ready=$true}}
function Sim-Health{try{$r=Invoke-WebRequest ($Sim+'/api/e5/sim-probe') -UseBasicParsing -TimeoutSec 5;return ([int]$r.StatusCode -eq 200)}catch{$false}}
function Set-Fault([bool]$enabled){$h=@{'X-E5-Runner'='local-fixed-e5'};$r=Invoke-RestMethod ($Sim+'/api/e5/sim-fault') -Method Post -Headers $h -ContentType 'application/json' -Body (@{enabled=$enabled}|ConvertTo-Json -Compress)-TimeoutSec 5;return [bool]($r.enabled -eq $enabled)}
function Probe([string]$phase){$at=[DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5));try{$r=Invoke-WebRequest ($Sim+'/api/e5/sim-probe') -UseBasicParsing -TimeoutSec 5;[pscustomobject]@{timestamp=$at.ToString('o');phase=$phase;status=[int]$r.StatusCode;message=[string]$r.Content;fresh=($null-eq$script:lastTimestamp-or$at.UtcDateTime-gt$script:lastTimestamp)}}catch{$status=0;$msg=$_.Exception.Message;if($_.Exception.Response){$status=[int]$_.Exception.Response.StatusCode.value__;try{$sr=[IO.StreamReader]::new($_.Exception.Response.GetResponseStream());$msg=$sr.ReadToEnd();$sr.Dispose()}catch{}};[pscustomobject]@{timestamp=$at.ToString('o');phase=$phase;status=$status;message=$msg;fresh=($null-eq$script:lastTimestamp-or$at.UtcDateTime-gt$script:lastTimestamp)}}finally{$script:lastTimestamp=$at.UtcDateTime}}
function Publish([object]$p){Invoke-RestMethod ($Engine+'/api/recovery/e5/sample') -Method Post -ContentType 'application/json' -Body (@{httpStatus=$p.status;timestamp=$p.timestamp}|ConvertTo-Json)-TimeoutSec 5|Out-Null;return [DateTimeOffset]::Now}
function Evaluate([bool]$execute){$query=if($execute){'execute=true'}else{'execute=false'};Invoke-RestMethod ($Engine+'/api/recovery/e5/evaluate?'+$query) -Method Post -TimeoutSec 20}
function Wait-E5Scrape([int]$count,[int]$action,[DateTimeOffset]$publishedAt){
 $countQuery='adaptive_recovery_e5_http_500_consecutive{job="adaptive-recovery-engine-e2"}'
 $actionQuery='adaptive_recovery_e5_simulated_action{job="adaptive-recovery-engine-e2"}'
 $base='http://127.0.0.1:19090/api/v1/query?query='
 $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20)
 $lastError='No fresh matching project Prometheus scrape within 20 seconds.'
 do{
  try{
   $cv=Invoke-RestMethod ($base+[uri]::EscapeDataString($countQuery)) -TimeoutSec 3
   $ct=Invoke-RestMethod ($base+[uri]::EscapeDataString('timestamp('+$countQuery+')')) -TimeoutSec 3
   $av=Invoke-RestMethod ($base+[uri]::EscapeDataString($actionQuery)) -TimeoutSec 3
   $at=Invoke-RestMethod ($base+[uri]::EscapeDataString('timestamp('+$actionQuery+')')) -TimeoutSec 3
   if(Test-E5ScrapeMatch -CountValue $cv -CountTimestamp $ct -ActionValue $av -ActionTimestamp $at -ExpectedCount $count -ExpectedAction $action -PublishedAt $publishedAt){
    $when=[DateTimeOffset]::FromUnixTimeMilliseconds([long][math]::Round(([double]$ct.data.result[0].value[1])*1000)).ToOffset([TimeSpan]::FromHours(5.5)).ToString('o')
    $run.telemetry.scrapes+=@{count=$count;action=$action;scrapedAt=$when}
    Save
    return $true
   }
  }catch{$lastError=$_.Exception.Message}
  if([DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Seconds 2}
 }while([DateTimeOffset]::UtcNow -lt $deadline)
 $run.telemetry.graphComplete=$false
 $run.telemetry.error="count=$count action=${action}: $lastError"
 Save
 return $false
}
try{
 $base=[pscustomobject]@{uid=$null;ready=(Sim-Health);health=(Sim-Health)};if(-not$base.ready){throw 'Preflight blocked: local E5 simulation endpoint is not healthy'};$run.baseline=[ordered]@{podUid=$null;ready=$base.ready;health=$base.health};Save
 if($CheckOnly){$run.result='CHECK_ONLY_PASS';$run.runStatus='Completed';$run.experimentOutcome='Not applicable — no live fault was created';$run.cleanup.status='Not applicable — no live fault was created';Save;exit 0}
 Invoke-RestMethod ($Engine+'/api/recovery/e5/start') -Method Post -Headers @{'X-E5-Runner'='local-fixed-e5'} -TimeoutSec 5|Out-Null
 $baselineProbe=Probe 'before';$run.samples+=$baselineProbe
 if($baselineProbe.status -ne 200 -or -not $baselineProbe.fresh){throw 'Preflight blocked: fresh E5 baseline HTTP 200 was not observed'}
 $baselinePublished=Publish $baselineProbe
 $baselineEvaluation=Evaluate $false;$baselineEvaluation|Add-Member -NotePropertyName execute -NotePropertyValue $false -Force;$run.engineEvaluations+=$baselineEvaluation;Save
 if($baselineEvaluation.decision -ne 'CONTINUE' -or $baselineEvaluation.signals.persistenceSamples -ne 0){throw 'Preflight blocked: E5 Engine did not reset to CONTINUE with zero consecutive HTTP 500 responses'}
 if(-not (Wait-E5Scrape 0 0 $baselinePublished)){throw 'Preflight blocked: Prometheus did not scrape the reset E5 baseline within 20 seconds'}
 if(-not(Set-Fault $true)){throw 'E5 fault enable was not confirmed'};$run.fault.enabled=$true;$run.timestamps.T0=(Get-Date).ToString('o');$run.timestampEvidence.T0='Fixed E5 fault endpoint confirmed enabled=true';$run.events+='Fault enabled';Save
 for($i=0;$i-lt 12;$i++){
  $p=Probe 'during';$run.samples+=$p;Save
  if($p.status -ne 500 -or -not $p.fresh){Start-Sleep -Milliseconds 750;continue}
  $published=Publish $p
  if(-not $run.timestamps.T1){$run.timestamps.T1=$p.timestamp;$run.timestampEvidence.T1='Dedicated E5 probe returned a distinct fresh HTTP 500';$run.events+='First HTTP 500 observed'}
  $ev=Evaluate $false;$ev|Add-Member -NotePropertyName execute -NotePropertyValue $false -Force;$run.engineEvaluations+=$ev
  $freshCount=@($run.samples|Where-Object {$_.phase -eq 'during' -and $_.status -eq 500 -and $_.fresh}).Count
  if($ev.signals.persistenceSamples -ne $freshCount){throw "E5 Engine persistence mismatch: expected $freshCount fresh HTTP 500 responses, received $($ev.signals.persistenceSamples)"}
  if($ev.decision -eq 'OBSERVE'){$run.events+='Engine observing below threshold'}
  if(-not $run.timestamps.T2 -and $ev.decision -ne 'CONTINUE'){$run.timestamps.T2=$ev.at;$run.timestampEvidence.T2='Engine preview response recorded'}
  Save
  if(-not (Wait-E5Scrape $freshCount 0 $published)){throw "Prometheus did not scrape E5 count $freshCount within 20 seconds; fault-off cleanup required"}
  if($freshCount -ge 3){break}
  Start-Sleep -Milliseconds 750
 }
 $high=@($run.samples|Where-Object {$_.phase -eq 'during' -and $_.status -eq 500 -and $_.fresh})
 if($high.Count -ge 3){
  $ev=Evaluate $true;$ev|Add-Member -NotePropertyName execute -NotePropertyValue $true -Force;$run.engineEvaluations+=$ev
  if($ev.decision -eq 'SIMULATED_RESTART' -and $ev.actionVerified){$acted=$true;$run.timestamps.T3=$ev.at;$run.timestampEvidence.T3='Engine execute=true response recorded simulated restart action';$run.events+='Simulated restart action recorded';$run.experimentOutcome='Simulated restart action recorded — no service was restarted';Save;if(-not (Wait-E5Scrape 3 1 ([DateTimeOffset]::Now))){$run.telemetry.graphComplete=$false}}
  else{$run.experimentOutcome='Action not verified — simulated restart was not recorded'}
 }else{$run.result='NOT_TRIGGERED';$run.experimentOutcome='Not triggered — HTTP 500 persistence threshold was not reached'}
 Save
}catch{$run.result='FAILED';$run.experimentOutcome=$_.Exception.Message;Save;throw}
finally{if($CheckOnly){$run.runStatus='Completed';$run.result='CHECK_ONLY_PASS';$run.cleanup.status='Not applicable — no live fault was created';Save;Write-Output "RUN_RECORD=$path"}else{
 try{
  $off=Set-Fault $false;$run.fault.enabled=$false;$run.cleanup.faultOff=$off;$run.events+='Fault disabled'
  $post=Probe 'after';$run.samples+=$post;$run.after.routeStatus=$post.status;$run.cleanup.routeRecovered=($post.status -eq 200 -and $post.fresh)
  if($run.cleanup.routeRecovered){$run.timestamps.T4=$post.timestamp;$run.timestampEvidence.T4='Fresh post-cleanup probe returned HTTP 200';$run.events+='Healthy HTTP 200 confirmed'}
  $run.after.podUid=$null;$run.after.ready=Sim-Health;$run.after.health=Sim-Health;$run.cleanup.ready=$run.after.ready;$run.cleanup.health=$run.after.health
  $run.timestamps.T5=if($run.cleanup.faultOff -and $run.cleanup.ready -and $run.cleanup.health -and $run.cleanup.routeRecovered){(Get-Date).ToString('o')}else{$null}
  if($run.timestamps.T5){$run.events+='Cleanup verified';$run.cleanup.status='Passed'}else{$run.cleanup.status='Failed'}
  $run.result=if($run.cleanup.status -ne 'Passed' -or $run.result -eq 'FAILED'){'FAILED'}elseif($acted){'PASSED'}else{'NOT_TRIGGERED'}
 }catch{$run.cleanup.status='Failed';$run.cleanup.error=$_.Exception.Message;$run.result='FAILED'}
 $run.runStatus=if($run.cleanup.status -eq 'Passed'){'Completed'}else{'Failed'};Save
 if($run.cleanup.routeRecovered){
  try{$postPublished=Publish $post;$postEvaluation=Evaluate $false;$postEvaluation|Add-Member -NotePropertyName execute -NotePropertyValue $false -Force;$run.engineEvaluations+=$postEvaluation;Save;if(-not (Wait-E5Scrape 0 ([int]$acted) $postPublished)){$run.telemetry.graphComplete=$false}elseif($run.telemetry.graphComplete -ne $false){$run.telemetry.graphComplete=$true}}
  catch{$run.telemetry.graphComplete=$false;$run.telemetry.error=$_.Exception.Message}
 }
 Save;Write-Output "RUN_RECORD=$path"
}}
