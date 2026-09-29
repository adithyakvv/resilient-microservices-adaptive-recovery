param(
  [switch]$CheckOnly,
  [string]$Namespace = 'resilient-microservices-adaptive-recovery',
  [string]$ChaosName = 'adaptive-inventory-e1-cpu',
  [double]$CpuThresholdCores = 0.10,
  [int]$Samples = 6,
  [int]$SampleIntervalSeconds = 5,
  [int]$SustainedSamples = 2
)
$ErrorActionPreference = 'Stop'
$kubectl = if ($env:KUBECTL_BIN) { $env:KUBECTL_BIN } else { (Get-Command kubectl -ErrorAction Stop).Source }
if (-not (Test-Path $kubectl)) { $kubectl = (Get-Command kubectl -ErrorAction Stop).Source }
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'e1-preflight.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'e1-postcleanup-telemetry.psm1') -Force
$manifest = Join-Path $root 'infrastructure/chaos/e1-inventory-cpu-stress.yaml'
$engine = 'http://127.0.0.1:8090'; $reports = Join-Path $root 'reports'; New-Item -ItemType Directory -Force -Path $reports | Out-Null
$started = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5)); $runId = 'E1-' + $started.ToString('yyyyMMdd-HHmmssK').Replace(':',''); $runPath = Join-Path $reports ("e1-inventory-cpu-" + $started.ToString('yyyyMMdd-HHmmssK').Replace(':','') + '.json'); $progressPath = Join-Path $reports 'e1-progress.json'
$created = $false; $uid = $null; $baseline = $null; $preflightBlocked = $false
$run = [ordered]@{
  experiment='E1'; runId=$runId; checkOnly=[bool]$CheckOnly; runStatus='Running'; result=$null; experimentOutcome=$null; definition='Inventory CPU load using Chaos Mesh StressChaos'; startedAt=$started.ToString('yyyy-MM-ddTHH:mm:sszzz'); timezone='Asia/Kolkata (+05:30)'; thresholdCores=$CpuThresholdCores; sustainedSamplesRequired=$SustainedSamples; thresholdNotSustained=$false; cpuImprovementObserved=$null;progressWriteStatus='Pending';progressWriteError=$null
  preflight=[ordered]@{status='Pending';message=$null;blockers=@();engineDecision=$null;engineReason=$null;engineAt=$null}
  timestamps=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T5=$null;timeToStableState=$null}; timestampDefinitions=[ordered]@{T0='Chaos Mesh confirms fault injection';T1='First Kubernetes Metrics API sample at or above the configured CPU threshold';T2='Actual execute=true Engine response that applies the CPU increase; preview evaluations excluded';T3='Kubernetes confirms increased CPU resources and Inventory readiness';T5='Exact baseline restoration and readiness verified'}; timestampEvidence=[ordered]@{}
  cpuReadings=@(); postCleanupTelemetry=[ordered]@{status='Pending';sourceTimestamp=$null;window=$null;windowStart=$null;pod=$null;podUid=$null;cpuCores=$null;prometheusScraped=$false;reason=$null}; engineEvaluations=@(); resources=[ordered]@{before=$null;during=@();after=$null}; chaos=[ordered]@{name=$ChaosName;uid=$null;status=$null;created=$false;deleted=$false}; readiness=[ordered]@{before=$null;after=$null}; cleanup=[ordered]@{attempted=$false;resourceDeleted=$false;restoreVerify=$false;error=$null}
}
function IstNow { [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:sszzz') }
function K([string[]]$KubectlArgs) { if($preflightBlocked -and $KubectlArgs.Count -ge 2 -and $KubectlArgs[0] -eq 'set' -and $KubectlArgs[1] -eq 'resources'){Write-Host 'Preflight blocked; baseline resource patch skipped.';return}; & $kubectl @KubectlArgs; if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($KubectlArgs -join ' ')" } }
function KJson([string[]]$KubectlArgs) { $text=(& $kubectl @KubectlArgs | Out-String); if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($KubectlArgs -join ' ')" }; $text|ConvertFrom-Json }
function Save-Run {
  if($run.result -eq 'BLOCKED' -and $run.cleanup.restoreVerify -and -not $run.cleanup.error){$run.runStatus='Blocked'}
  # The shared progress snapshot is best-effort: a reader or another Windows
  # process can briefly hold it open. That must not turn a successful Engine
  # response into an evaluation error or prevent the unique final report from
  # preserving independently observed experiment/cleanup outcomes.
  $run.progressWriteStatus='Saved';$run.progressWriteError=$null
  try { $json=$run|ConvertTo-Json -Depth 12; $json|Set-Content -Encoding UTF8 -ErrorAction Stop $progressPath }
  catch { $run.progressWriteStatus='Unavailable';$run.progressWriteError=$_.Exception.Message;Write-Warning ('Progress snapshot unavailable; final run report will still be written: '+$run.progressWriteError) }
  $json=$run|ConvertTo-Json -Depth 12
  $json|Set-Content -Encoding UTF8 -ErrorAction Stop $runPath
}
function Add-Evidence([string]$Name,[string]$Value) { $run.timestampEvidence[$Name]=$Value }
function Resources($d) { $c=$d.spec.template.spec.containers|Where-Object name -eq 'adaptive-inventory-service'|Select-Object -First 1; [ordered]@{cpuRequest=$c.resources.requests.cpu;cpuLimit=$c.resources.limits.cpu;memoryRequest=$c.resources.requests.memory;memoryLimit=$c.resources.limits.memory} }
function Get-Deployment { KJson @('-n',$Namespace,'get','deployment','adaptive-inventory-service','-o','json') }
function Get-Readiness($d) { [int]$d.status.readyReplicas -eq [int]$d.spec.replicas }
function Get-CurrentReadyInventoryPod {
  $pods=KJson @('-n',$Namespace,'get','pods','-o','json')
  @($pods.items|Where-Object{$_.metadata.name -like 'adaptive-inventory-service-*' -and @($_.status.conditions|Where-Object{$_.type -eq 'Ready' -and $_.status -eq 'True'}).Count -gt 0}|Select-Object -First 1)[0]
}
function Test-ChaosAbsent {
  $text=(& $kubectl -n $Namespace get stresschaos $ChaosName --ignore-not-found -o json | Out-String)
  if($LASTEXITCODE -ne 0){return $false}
  return [string]::IsNullOrWhiteSpace($text)
}
function Mark-E1TelemetryUnavailable([string]$reason) {
  $run.postCleanupTelemetry.status='GRAPH_INCOMPLETE';$run.postCleanupTelemetry.reason=$reason
  Add-Evidence 'postCleanupCpu' ('Unavailable: '+$reason)
  try { Invoke-RestMethod ($engine+'/api/recovery/e1/unavailable') -Method Post -TimeoutSec 5 | Out-Null }
  catch { $run.postCleanupTelemetry.reason += '; exporter invalidation failed: '+$_.Exception.Message }
  Save-Run
}
function Wait-E1Scrape([double]$cores,[string]$sourceTimestamp,[DateTimeOffset]$publishedAt) {
  $prom='http://127.0.0.1:19090/api/v1/query?query='
  $query='adaptive_recovery_e1_cpu_source_timestamp_seconds{job="adaptive-recovery-engine-e2"}'
  $sourceSeconds=([DateTimeOffset]::Parse($sourceTimestamp).ToUnixTimeMilliseconds()/1000.0)
  for($n=0;$n -lt 8;$n++){
    try {
      $r=Invoke-RestMethod ($prom+[uri]::EscapeDataString($query)) -TimeoutSec 5
      $v=@($r.data.result|Select-Object -First 1)[0]
      if($v -and [math]::Abs([double]$v.value[1]-$sourceSeconds) -lt .001 -and [double]$v.value[0] -ge $publishedAt.ToUnixTimeSeconds()){
        $cpu=Invoke-RestMethod ($prom+[uri]::EscapeDataString('adaptive_recovery_e1_cpu_cores{job="adaptive-recovery-engine-e2"}')) -TimeoutSec 5
        $point=@($cpu.data.result|Select-Object -First 1)[0]
        if($point -and [math]::Abs([double]$point.value[1]-$cores) -lt .0000001){return $true}
      }
    } catch {}
    Start-Sleep 5
  }
  return $false
}
function Read-FinalCPU([string]$cleanupCompletedAt) {
  $last=@($run.cpuReadings|Where-Object phase -eq 'during'|Select-Object -Last 1)[0]
  $why='no fresh post-cleanup Metrics API window was observed within 90 seconds'
  for($n=0;$n -lt 18;$n++){
    try {
      $pod=Get-CurrentReadyInventoryPod
      if(-not$pod){$why='current Inventory pod is not Ready'}
      else {
        $r=Read-CPU 'after' $false $false $pod.metadata.name
        $check=Test-E1PostCleanupSample -Reading $r -CleanupCompletedAt $cleanupCompletedAt -LastStressSourceTimestamp $(if($last){$last.sourceTimestamp}else{$null}) -CurrentPodName $pod.metadata.name -CurrentPodUid $pod.metadata.uid
        if($check.passed){
          $r.podUid=$pod.metadata.uid;$r.windowStart=$check.windowStart
          $run.cpuReadings+=$r
          $run.postCleanupTelemetry.sourceTimestamp=$r.sourceTimestamp;$run.postCleanupTelemetry.window=$r.window;$run.postCleanupTelemetry.windowStart=$r.windowStart;$run.postCleanupTelemetry.pod=$r.pod;$run.postCleanupTelemetry.podUid=$r.podUid;$run.postCleanupTelemetry.cpuCores=$r.cpuCores
          $publishedAt=[DateTimeOffset]::UtcNow
          if(Publish-E1Sample $r){
            $run.postCleanupTelemetry.prometheusScraped=Wait-E1Scrape $r.cpuCores $r.sourceTimestamp $publishedAt
            $run.postCleanupTelemetry.status=if($run.postCleanupTelemetry.prometheusScraped){'Scraped'}else{'GRAPH_INCOMPLETE'}
            $run.postCleanupTelemetry.reason=if($run.postCleanupTelemetry.prometheusScraped){'Fresh measured post-cleanup CPU was scraped by Prometheus.'}else{'Fresh CPU was published, but no confirming Prometheus scrape was observed.'}
            Add-Evidence 'postCleanupCpu' ("Metrics API source $($r.sourceTimestamp), window $($r.window), pod UID $($r.podUid): $($r.raw) ($($r.cpuCores) cores). $($run.postCleanupTelemetry.reason)")
            Save-Run;return $r
          }
          $why='fresh reading could not be published to the E1 exporter';break
        }
        $why=$check.reason
      }
    } catch { $why=$_.Exception.Message }
    Start-Sleep 5
  }
  Mark-E1TelemetryUnavailable $why
  return $null
}
function Get-ChaosStatus { try { $c=KJson @('-n',$Namespace,'get','stresschaos',$ChaosName,'-o','json'); $injected=@($c.status.conditions|Where-Object{$_.type -in @('Injected','AllInjected') -and $_.status -eq 'True'}).Count -gt 0; [ordered]@{phase=$c.status.phase;injected=$injected;injectionCondition=if(@($c.status.conditions|Where-Object{$_.type -eq 'AllInjected' -and $_.status -eq 'True'}).Count){'AllInjected=True'}else{'Injected=True'};conditions=$c.status.conditions} } catch { $null } }
function Wait-Injected { for($i=0;$i-lt 6;$i++){ $s=Get-ChaosStatus;if($s){$run.chaos.status=$s};if($s -and $s.injected){return $true};Start-Sleep 1 };return $false }
function Publish-E1Sample($reading) { if($reading -and (-not [double]::IsNaN([double]$reading.cpuCores) -and -not [double]::IsInfinity([double]$reading.cpuCores)) -and [double]$reading.cpuCores -ge 0) { try { $body=@{cpuCores=[double]$reading.cpuCores};if($reading.sourceTimestamp){$body.sourceTimestamp=[string]$reading.sourceTimestamp};Invoke-RestMethod ($engine+'/api/recovery/e1/sample') -Method Post -ContentType 'application/json' -Body ($body|ConvertTo-Json) -TimeoutSec 5 | Out-Null;return $true } catch { Add-Evidence 'metrics' ('E1 sample publish unavailable: '+$_.Exception.Message) } };return $false }
function Read-CPU([string]$phase,[bool]$publish=$true,[bool]$record=$true,[string]$targetPodName=$null) { $m=KJson @('get','--raw',"/apis/metrics.k8s.io/v1beta1/namespaces/$Namespace/pods");$pod=@($m.items|Where-Object{$_.metadata.name-like'adaptive-inventory-service-*' -and (-not$targetPodName -or $_.metadata.name -eq $targetPodName)}|Select-Object -First 1);if(-not$pod){return $null};$c=@($pod.containers|Where-Object name -eq 'adaptive-inventory-service'|Select-Object -First 1);if(-not$c){return $null};$raw=[string]$c.usage.cpu;$cores=if($raw.EndsWith('n')){[double]$raw.TrimEnd('n')/1e9}elseif($raw.EndsWith('u')){[double]$raw.TrimEnd('u')/1e6}elseif($raw.EndsWith('m')){[double]$raw.TrimEnd('m')/1e3}else{[double]$raw};$reading=[ordered]@{timestamp=IstNow;sourceTimestamp=if($pod.timestamp){([DateTimeOffset]$pod.timestamp).ToString('o')}else{$null};phase=$phase;pod=$pod.metadata.name;container=$c.name;cpuCores=$cores;raw=$raw;window=$pod.window};if($record){$run.cpuReadings+=$reading};if($publish){$null=Publish-E1Sample $reading};return $reading }
function Eval([bool]$execute,[string]$phase) { try{$requestedAt=IstNow;$r=Invoke-RestMethod ($engine+'/api/recovery/evaluate/adaptive-inventory-service?execute='+$execute.ToString().ToLower()) -Method Post -TimeoutSec 8;$responseAt=IstNow;$run.engineEvaluations+=[ordered]@{timestamp=$responseAt;requestedAt=$requestedAt;phase=$phase;execute=$execute;decision=$r.decision;reason=$r.reason;actionVerified=$r.actionVerified;response=$r};Save-Run;return $r}catch{$run.engineEvaluations+=[ordered]@{timestamp=IstNow;phase=$phase;execute=$execute;error=$_.Exception.Message};Save-Run;return $null} }
try {
  $d=Get-Deployment;$baseline=Resources $d;$run.resources.before=$baseline;$run.readiness.before=Get-Readiness $d;Save-Run
  if($CheckOnly){K @('apply','--dry-run=server','-f',$manifest);$run.result='CHECK_ONLY_PASS'} else {
    $gate=Invoke-E1PreflightGate -RequiredPersistenceSamples 3 -MaximumAgeSeconds 30 -Evaluate { Eval $false 'preflight' } -OnPass { $true }
    $preflightEval=if($run.engineEvaluations.Count -gt 0){$run.engineEvaluations[-1]}else{$null}
    $preflightBlockers=@($gate.blockers);if($preflightEval-and$preflightEval.error){$preflightBlockers+=('Engine request error: '+$preflightEval.error)}
    $run.preflight.engineDecision=if($preflightEval){$preflightEval.decision}else{$null};$run.preflight.engineReason=if($preflightEval){if($preflightEval.reason){$preflightEval.reason}else{$preflightEval.error}}else{$null};$run.preflight.engineAt=if($preflightEval){$preflightEval.timestamp}else{$null};$run.preflight.blockers=$preflightBlockers
    if(-not $gate.passed){$preflightBlocked=$true;$run.preflight.status='Blocked';$run.preflight.message=($preflightBlockers -join '; ');$run.result='BLOCKED';$run.runStatus='Blocked';$run.experimentOutcome='BLOCKED';Add-Evidence 'preflight' ('No Chaos was created and no actuator was requested. '+$run.preflight.message);Save-Run}
    else {
    $run.preflight.status='Passed';$run.preflight.message='Fresh Engine signals are available; E1 may proceed.';Save-Run
    K @('apply','-f',$manifest);$created=$true;$run.chaos.created=$true;$chaos=KJson @('-n',$Namespace,'get','stresschaos',$ChaosName,'-o','json');$uid=$chaos.metadata.uid;$run.chaos.uid=$uid
    if(Wait-Injected){$run.timestamps.T0=IstNow;Add-Evidence 'T0' 'Chaos Mesh StressChaos status.conditions[type=Injected,status=True] after apply.'}else{Add-Evidence 'T0' 'Chaos resource existed but Injected=True was not observed.'};Save-Run
    $above=0;$executed=$false;$actionResponse=$null
    $triggerCpu=$null;$actionVerified=$false;$actionObservationPending=$false;$actionIteration=-1
    for($i=0;$i-lt $Samples;$i++){Start-Sleep $SampleIntervalSeconds;$reading=Read-CPU 'during';if($reading){if($reading.cpuCores-ge$CpuThresholdCores){$above++;if(-not$run.timestamps.T1){$run.timestamps.T1=$reading.timestamp;$t1Cpu=$reading.cpuCores;Add-Evidence 'T1' "First Kubernetes Metrics API sample $($reading.raw) ($($reading.cpuCores) cores) met the configured threshold.";Save-Run}}else{$above=0}};$null=Eval $false 'during';if($above-ge$SustainedSamples-and-not$executed){$executed=$true;$actionIteration=$i;$triggerCpu=if($reading){$reading.cpuCores}else{$null};$actionResponse=Eval $true 'actuator';if($actionResponse-and$actionResponse.decision-eq'INCREASE_CPU'-and$actionResponse.actionVerified-eq$true){if(-not$run.timestamps.T2){$run.timestamps.T2=$run.engineEvaluations[-1].timestamp;Add-Evidence 'T2' 'Actual execute=true INCREASE_CPU response with actionVerified=true; preview and rejected requests are excluded.';Save-Run}};if($actionResponse-and$actionResponse.decision-eq'INCREASE_CPU'){$during=Resources (Get-Deployment);$run.resources.during+=$during;$appliedReady=($during.cpuRequest-ne$baseline.cpuRequest-or$during.cpuLimit-ne$baseline.cpuLimit)-and(Get-Readiness (Get-Deployment));if($appliedReady){$run.timestamps.T3=IstNow;Add-Evidence 'T3' 'Kubernetes Deployment shows increased CPU resources and Inventory is Ready.';Save-Run;$actionVerified=[bool]$actionResponse.actionVerified;$actionObservationPending=$actionVerified}}};Save-Run}
    if($executed){$run.result='ACTION_REQUESTED';$run.experimentOutcome='CPU_ACTION_REQUESTED'}else{$run.result='NOT_TRIGGERED';$run.experimentOutcome='NOT_TRIGGERED';$run.thresholdNotSustained=($above -gt 0 -and $above -lt $SustainedSamples);if($run.thresholdNotSustained){Add-Evidence 'threshold' "Threshold not sustained: $above of $SustainedSamples required consecutive samples were above $CpuThresholdCores cores.";Save-Run}}
    }
  }
} catch {$run.result='FAILED';$run.cleanup.error=$_.Exception.Message;throw}
finally {
  $run.cleanup.attempted=$true
  try {
    if($created){
      $cur=(& $kubectl -n $Namespace get stresschaos $ChaosName -o json 2>$null|ConvertFrom-Json)
      if($cur-and$cur.metadata.uid-eq$uid){K @('delete','stresschaos',$ChaosName,'-n',$Namespace,'--wait=true');$run.cleanup.resourceDeleted=$true;$run.chaos.deleted=$true}
    }
    if($baseline){
      if($CheckOnly){$run.resources.after=$baseline;$run.readiness.after=$run.readiness.before;$run.cleanup.restoreVerify=$true}
      else {
        K @('set','resources','deployment','adaptive-inventory-service','-n',$Namespace,'-c','adaptive-inventory-service',"--requests=cpu=$($baseline.cpuRequest),memory=$($baseline.memoryRequest)","--limits=cpu=$($baseline.cpuLimit),memory=$($baseline.memoryLimit)")
        K @('rollout','status','deployment/adaptive-inventory-service','-n',$Namespace,'--timeout=180s')
        $restored=Get-Deployment;$after=Resources $restored;$run.resources.after=$after;$run.readiness.after=Get-Readiness $restored
        $run.cleanup.restoreVerify=($run.readiness.after-and($after.cpuRequest-eq$baseline.cpuRequest)-and($after.cpuLimit-eq$baseline.cpuLimit)-and($after.memoryRequest-eq$baseline.memoryRequest)-and($after.memoryLimit-eq$baseline.memoryLimit))
      }
      if(-not$CheckOnly-and$run.cleanup.restoreVerify-and-not$run.timestamps.T5){$run.timestamps.T5=IstNow;Add-Evidence 'T5' 'Exact resource comparison and configured replica readiness passed after cleanup.'}
      $markers=@('T0','T1','T2','T3','T5');$valid=$true;$last=$null
      foreach($marker in $markers){$value=$run.timestamps[$marker];if(-not$value){$valid=$false;break};$parsed=[DateTimeOffset]::Parse($value);if($last-and$parsed-lt$last){$valid=$false;break};$last=$parsed}
      if($valid){$run.timestamps.timeToStableState=([DateTimeOffset]::Parse($run.timestamps.T5)-[DateTimeOffset]::Parse($run.timestamps.T0)).ToString()}
      else{$run.timestamps.timeToStableState=$null;Add-Evidence 'timeToStableState' 'Unavailable because one or more required T0-T3 or T5 markers is missing or out of order.'}
    }
  } catch {$run.cleanup.error=$_.Exception.Message;$run.cleanup.restoreVerify=$false}
  # Telemetry is separate from the experiment and restoration verdict. Never
  # publish an old stress window as a post-cleanup observation.
  if($created -and -not$CheckOnly){
    try {
      if($run.cleanup.restoreVerify -and (Test-ChaosAbsent)){
        $cleanupCompletedAt=IstNow
        $null=Read-FinalCPU $cleanupCompletedAt
      } else { Mark-E1TelemetryUnavailable 'Chaos absence or exact baseline/readiness was not independently verified' }
    } catch { try { Mark-E1TelemetryUnavailable ('post-cleanup telemetry error: '+$_.Exception.Message) } catch {} }
  }
  $run.runStatus=if($run.cleanup.restoreVerify-and-not$run.cleanup.error){'Completed'}else{'Failed'}
  if($run.runStatus -eq 'Failed'){$run.experimentOutcome='FAILED'}
  Save-Run
  if($run.cleanup.restoreVerify){'RESTORE_VERIFY=PASS'}else{'RESTORE_VERIFY=FAIL_OR_UNAVAILABLE'}
  "RUN_RECORD=$runPath"
}
