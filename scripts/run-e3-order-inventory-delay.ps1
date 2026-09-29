param([switch]$CheckOnly,[string]$Namespace='resilient-microservices-adaptive-recovery')
$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent;$reports=Join-Path $root 'reports';New-Item -ItemType Directory -Force $reports|Out-Null;Import-Module (Join-Path $PSScriptRoot 'e3-reporting.psm1') -Force;$now=[DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5));$runId='E3-'+$now.ToString('yyyyMMdd-HHmmssK').Replace(':','');$path=Join-Path $reports ('e3-order-inventory-delay-'+$now.ToString('yyyyMMdd-HHmmssK').Replace(':','')+'.json');$delayMs=1000
$run=[ordered]@{experiment='E3';runId=$runId;runStatus='Running';result=$null;experimentOutcome=$null;definition='Order to Inventory deterministic application-level delay';mode='APPLICATION_DELAY';delay="${delayMs}ms bounded application delay; explicit disable required (no TTL)";timestamps=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T4=$null;T5=$null};timestampDefinitions=[ordered]@{T0='Order confirms the application delay is enabled';T1='First completed Order-to-Inventory probe during the enabled delay';T2='Engine non-mutating evaluation response received';T3='Order confirms the application delay is disabled';T4='First completed Order-to-Inventory probe after delay disable';T5='Cleanup and Order/Inventory readiness verification complete'};timestampEvidence=[ordered]@{};durations=[ordered]@{};chaos=[ordered]@{name=$null;uid=$null;created=$false;deletionRequested=$false;deleted=$false;absenceVerified=$true;status='Not applicable — application delay'};readiness=[ordered]@{before=$null;after=$null};measurements=@();medians=[ordered]@{before=$null;during=$null;after=$null};graph=[ordered]@{before=[ordered]@{status='Pending'};during=[ordered]@{status='Pending'};after=[ordered]@{status='Pending'}};engineEvaluations=@();cleanup=[ordered]@{attempted=$false;restoreVerify=$false;status=$null;error=$null}}
function Save-Run{$j=$run|ConvertTo-Json -Depth 16;$j|Set-Content -Encoding UTF8 $path;$j|Set-Content -Encoding UTF8 (Join-Path $reports 'e3-progress.json')}
function Record-E3Event([string]$Event,[string]$Timestamp,[string]$Evidence){if(Set-E3ObservedTimestamp -Run $run -Event $Event -Timestamp $Timestamp -Evidence $Evidence){Save-Run;return $true};return $false}
function IstNow{[DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')}
function Ready([string]$name){$k=if($env:KUBECTL_BIN){$env:KUBECTL_BIN}else{(Get-Command kubectl -ErrorAction Stop).Source};$d=& $k -n $Namespace get deployment $name -o json|ConvertFrom-Json;[int]$d.status.readyReplicas -eq [int]$d.spec.replicas}
function Set-Delay([bool]$enabled){$expectedDelay=if($enabled){$delayMs}else{0};$response=Invoke-RestMethod 'http://127.0.0.1:18083/api/internal/e3-delay' -Method Post -ContentType 'application/json' -Body (@{enabled=$enabled;delayMs=$expectedDelay}|ConvertTo-Json);if([bool]$response.enabled -ne $enabled -or [int]$response.delayMs -ne $expectedDelay){throw "Order delay endpoint did not confirm enabled=$enabled and delayMs=$expectedDelay"};return $response}
function Probe([int]$number,[string]$phase){$base='http://127.0.0.1:18083';$before=@(Invoke-RestMethod "$base/api/orders").Count;$payload=(Invoke-WebRequest 'http://127.0.0.1:18081/api/products' -UseBasicParsing -TimeoutSec 10).Content|ConvertFrom-Json;$p=@($payload)[0];if($null -eq $p){throw 'No product available for safe dependency probe'};$id=$p.id;if($id -is [array]){$id=@($id)[0]};$productId=[Convert]::ToInt64($id);$quantity=2147483647;$sw=[Diagnostics.Stopwatch]::StartNew();$status=0;$message='';try{$r=Invoke-WebRequest "$base/api/orders" -Method Post -ContentType 'application/json' -Body (@{productId=$productId;quantity=$quantity}|ConvertTo-Json) -UseBasicParsing -TimeoutSec 15;$status=[int]$r.StatusCode;$message=[string]$r.Content}catch{if($_.Exception.Response){$status=[int]$_.Exception.Response.StatusCode.value__;try{$sr=[IO.StreamReader]::new($_.Exception.Response.GetResponseStream());$message=$sr.ReadToEnd();$sr.Dispose()}catch{$message=$_.Exception.Message}}else{$message=$_.Exception.Message}}finally{$sw.Stop()};$after=@(Invoke-RestMethod "$base/api/orders").Count;$persisted=$after-ne $before;$ok=$status-eq 409-and-not $persisted;[ordered]@{requestNumber=$number;phase=$phase;timestamp=[DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz');latencyMs=[math]::Round($sw.Elapsed.TotalMilliseconds,3);productId=$productId;requestedQuantity=$quantity;httpStatus=$status;responseMessage=$message;orderCountBefore=$before;orderCountAfter=$after;orderPersisted=$persisted;probeSuccess=$ok;probeFailure=(-not $ok);probeTotal=1;safeRejectionSummary=if($ok){'Rejected safely - HTTP 409; order count unchanged; no order created'}else{'Unverified - actual response/counts did not match expected rejection'}}}
function AddSample([string]$phase){
  $m=Probe (@($run.measurements).Count+1) $phase
  $m['metricPublished']=$false
  $m['metricPublishedAt']=$null
  if($m.probeSuccess){
    try{
      Invoke-RestMethod 'http://127.0.0.1:8090/api/recovery/e3/sample' -Method Post -ContentType 'application/json' -Body (@{latencyMs=$m.latencyMs;probeSuccesses=1;probeFailures=0}|ConvertTo-Json)|Out-Null
      $m.metricPublished=$true
      $m.metricPublishedAt=IstNow
    }catch{$m['metricError']=$_.Exception.Message}
  }else{$m['metricError']='Not published as successful latency: safe HTTP 409/count check failed.'}
  $run.measurements+=$m
  $eventSaved=$false
  if($phase -eq 'during' -and -not $run.timestamps.T1){$eventSaved=Record-E3Event 'T1' $m.timestamp 'Timestamp from the first completed safe Order probe while the delay was confirmed enabled.'}
  elseif($phase -eq 'after' -and -not $run.timestamps.T4){$eventSaved=Record-E3Event 'T4' $m.timestamp 'Timestamp from the first completed safe Order probe after the delay endpoint confirmed it was disabled.'}
  if(-not $eventSaved){Save-Run}
}
function Wait-E3PhaseScrape([string]$phase){
  $sample=@($run.measurements|Where-Object {$_.phase -eq $phase -and $_.probeSuccess -and $_.metricPublished}|Select-Object -Last 1)
  if($sample.Count -ne 1){$run.graph[$phase]=[ordered]@{status='Unavailable';reason='No successful safe probe was published in this phase.'};Save-Run;return $false}
  $sample=$sample[0]
  $publishedAt=[DateTimeOffset]::Parse([string]$sample.metricPublishedAt)
  $query='adaptive_order_inventory_latency_ms{job="adaptive-recovery-engine-e3"}'
  $url='http://127.0.0.1:19090/api/v1/query?query='
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20)
  $lastError='No matching fresh Prometheus scrape within 20 seconds.'
  do{
    try{
      $value=Invoke-RestMethod ($url+[uri]::EscapeDataString($query)) -TimeoutSec 3
      $timestamp=Invoke-RestMethod ($url+[uri]::EscapeDataString('timestamp('+$query+')')) -TimeoutSec 3
      if(Test-E3ScrapeMatch -ValueResponse $value -TimestampResponse $timestamp -ExpectedLatencyMs ([double]$sample.latencyMs) -PublishedAt $publishedAt){
        $scrapeUnix=[double]$timestamp.data.result[0].value[1]
        $scrapeAt=[DateTimeOffset]::FromUnixTimeMilliseconds([long][math]::Round($scrapeUnix*1000)).ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        $run.graph[$phase]=[ordered]@{status='Confirmed';requestNumber=$sample.requestNumber;latencyMs=$sample.latencyMs;sourceTimestamp=$sample.timestamp;publishedAt=$sample.metricPublishedAt;scrapedAt=$scrapeAt}
        Save-Run
        return $true
      }
    }catch{$lastError=$_.Exception.Message}
    if([DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Seconds 2}
  }while([DateTimeOffset]::UtcNow -lt $deadline)
  $run.graph[$phase]=[ordered]@{status='Unavailable';requestNumber=$sample.requestNumber;latencyMs=$sample.latencyMs;sourceTimestamp=$sample.timestamp;publishedAt=$sample.metricPublishedAt;reason=$lastError}
  Save-Run
  return $false
}
function Medians{$run.medians=[ordered]@{};foreach($p in 'before','during','after'){$values=@($run.measurements|Where-Object {$_.phase -eq $p}|ForEach-Object {[double]$_.latencyMs});$run.medians[$p]=Get-E3Median -Values $values}}
try{$run.readiness.before=(Ready 'adaptive-order-service' -and Ready 'adaptive-inventory-service');Save-Run;if($CheckOnly){$run.result='CHECK_ONLY_PASS';$run.cleanup.status='Not applicable — no live fault was created'}else{for($i=0;$i-lt 3;$i++){AddSample 'before';if($i-lt 2){Start-Sleep 1}};if(-not (Wait-E3PhaseScrape 'before')){throw 'E3 successful baseline latency did not reach Prometheus; delay was not enabled.'};$null=Set-Delay $true;Record-E3Event 'T0' (IstNow) 'Order /api/internal/e3-delay POST response confirmed enabled=true and delayMs=1000.';Start-Sleep 1;for($i=0;$i-lt 3;$i++){AddSample 'during';if($i-lt 2){Start-Sleep 1}};$a=Invoke-RestMethod 'http://127.0.0.1:8090/api/recovery/evaluate/adaptive-order-service?execute=false' -Method Post;$decisionAt=IstNow;$run.engineEvaluations+=[ordered]@{timestamp=$decisionAt;execute=$false;decision=$a.decision;reason=$a.reason;actionVerified=$a.actionVerified};Record-E3Event 'T2' $decisionAt 'Timestamp immediately after the actual execute=false Engine evaluation response was received.';$run.result='OBSERVED';$run.experimentOutcome='OBSERVE_ONLY';Save-Run;if(-not (Wait-E3PhaseScrape 'during')){throw 'E3 during-delay latency was not confirmed in a fresh Prometheus scrape; delay will be disabled in cleanup.'}}}catch{$run.result='FAILED';$run.cleanup.error=$_.Exception.Message;throw}finally{$run.cleanup.attempted=$true;if(-not $CheckOnly){try{$null=Set-Delay $false;Record-E3Event 'T3' (IstNow) 'Order /api/internal/e3-delay POST response confirmed enabled=false and delayMs=0.';Start-Sleep 1;for($i=0;$i-lt 3;$i++){AddSample 'after';if($i-lt 2){Start-Sleep 1}};$run.readiness.after=(Ready 'adaptive-order-service' -and Ready 'adaptive-inventory-service');$run.cleanup.restoreVerify=$run.readiness.after;$run.cleanup.status=if($run.cleanup.restoreVerify){'Passed'}else{'Failed'};if($run.cleanup.restoreVerify){Record-E3Event 'T5' (IstNow) 'Cleanup confirmed delay off and both Order and Inventory Deployments Ready.';[void](Wait-E3PhaseScrape 'after')}}catch{$run.cleanup.error=$_.Exception.Message;$run.cleanup.status='Failed'}}else{$run.runStatus='Completed'};Medians;if(-not $CheckOnly){$run.runStatus=if($run.cleanup.restoreVerify){'Completed'}else{'Failed'}};Save-Run};"RUN_RECORD=$path"
