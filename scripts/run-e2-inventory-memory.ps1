param(
  [switch]$CheckOnly,
  [string]$Namespace = 'resilient-microservices-adaptive-recovery',
  [string]$ChaosName = 'adaptive-inventory-e2-memory',
  [double]$MemoryThresholdRatio = 0.65,
  [double]$BaselineGuardRatio = 0.55,
  [double]$SafetyCapRatio = 0.82,
  [int]$Samples = 8,
  [int]$SampleIntervalSeconds = 5,
  [int]$SustainedSamples = 2,
  [int]$BaselineSamplesRequired = 3,
  [int]$BaselineTimeoutSeconds = 65,
  [int]$BaselinePollSeconds = 5
)
$ErrorActionPreference = 'Stop'
$kubectl = if ($env:KUBECTL_BIN) { $env:KUBECTL_BIN } else { (Get-Command kubectl -ErrorAction Stop).Source }
if (-not (Test-Path $kubectl)) { $kubectl = (Get-Command kubectl -ErrorAction Stop).Source }
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'e2-finalization.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'e2-postcleanup.psm1') -Force
$manifest = Join-Path $root 'infrastructure/chaos/e2-inventory-memory-stress.yaml'
$engine = 'http://127.0.0.1:8090'; $reports = Join-Path $root 'reports'; New-Item -ItemType Directory -Force -Path $reports | Out-Null
$started = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5)); $runId = 'E2-' + $started.ToString('yyyyMMdd-HHmmssK').Replace(':',''); $runPath = Join-Path $reports ("e2-inventory-memory-" + $started.ToString('yyyyMMdd-HHmmssK').Replace(':','') + '.json'); $progressPath = Join-Path $reports 'e2-progress.json'
$created = $false; $uid = $null; $baseline = $null; $script:lastMetricsSample = $null; $script:lastPublishOk = $false; $script:lastPublishAt = $null
$run = [ordered]@{
  experiment='E2'; runId=$runId; runStatus='Running'; result=$null; experimentOutcome=$null; definition='Inventory memory load using Chaos Mesh StressChaos'; startedAt=$started.ToString('yyyy-MM-ddTHH:mm:sszzz'); timezone='Asia/Kolkata (+05:30)'; thresholdMemoryRatio=$MemoryThresholdRatio; safetyCapRatio=$SafetyCapRatio; safetyCapReached=$false; sustainedSamplesRequired=$SustainedSamples; thresholdNotSustained=$false; memoryImprovementObserved=$null
  timestamps=[ordered]@{T0=$null;T1=$null;T2=$null;T3=$null;T5=$null;timeToStableState=$null}; timestampDefinitions=[ordered]@{T0='Chaos Mesh confirms fault injection';T1='First Kubernetes Metrics API sample at or above the configured memory ratio threshold';T2='Actual execute=true Engine INCREASE_MEMORY response; preview evaluations excluded';T3='Kubernetes confirms increased memory resources and Inventory readiness';T5='Exact baseline restoration and readiness verified'}; timestampEvidence=[ordered]@{}
  memoryReadings=@(); engineEvaluations=@(); resources=[ordered]@{before=$null;during=@();after=$null}; chaos=[ordered]@{name=$ChaosName;uid=$null;status=$null;created=$false;deletionRequested=$false;deleted=$false;absenceVerified=$false;deletionOutcome=$null}; readiness=[ordered]@{before=$null;after=$null}; cleanup=[ordered]@{attempted=$false;deletionRequested=$false;deletionOutcome=$null;resourceDeleted=$false;absenceVerified=$false;baselineVerified=$false;rolloutVerified=$false;readinessVerified=$false;restoreVerify=$false;status=$null;error=$null}; graph=[ordered]@{status='Pending';reason=$null;sourceTimestamp=$null;sourceWindow=$null;podUid=$null;memoryBytes=$null;memoryRatio=$null;publishedAt=$null;scrapedAt=$null}; reportWriting=[ordered]@{progressStatus='Pending';progressError=$null;finalReportStatus='Pending';finalReportError=$null}; preflight=[ordered]@{baselineMemoryRatio=$null;baselineGuardRatio=$BaselineGuardRatio;blocked=$false;samplesRequired=$BaselineSamplesRequired;samples=@();reason=$null}
}
function IstNow { [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:sszzz') }
function K([string[]]$KubectlArgs) { & $kubectl @KubectlArgs; if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($KubectlArgs -join ' ')" } }
function KJson([string[]]$KubectlArgs) { $text=(& $kubectl @KubectlArgs | Out-String); if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($KubectlArgs -join ' ')" }; $text|ConvertFrom-Json }
function Save-Run {
  # Progress is a best-effort GUI stream. A reader may briefly lock that file;
  # persistence errors are tracked separately and must not alter run outcomes.
  $writeResult = Write-E2RunArtifacts -Run $run -ProgressPath $progressPath -ReportPath $runPath
  if ($writeResult.progressStatus -eq 'Failed') { Write-Warning ("E2 progress report write failed (run report remains independent): " + $writeResult.progressError) }
  if ($writeResult.finalReportStatus -eq 'Failed') { Write-Warning ("E2 final report write failed: " + $writeResult.finalReportError) }
}
function Add-Evidence([string]$Name,[string]$Value) { $run.timestampEvidence[$Name]=$Value }
function Resources($d) { $c=$d.spec.template.spec.containers|Where-Object name -eq 'adaptive-inventory-service'|Select-Object -First 1; [ordered]@{cpuRequest=$c.resources.requests.cpu;cpuLimit=$c.resources.limits.cpu;memoryRequest=$c.resources.requests.memory;memoryLimit=$c.resources.limits.memory} }
function Get-Deployment { KJson @('-n',$Namespace,'get','deployment','adaptive-inventory-service','-o','json') }
function Get-Readiness($d) { [int]$d.spec.replicas -ge 1 -and [int]$d.status.readyReplicas -eq [int]$d.spec.replicas }
function Invoke-KubectlCaptured([string[]]$KubectlArgs) {
  $previousPreference=$ErrorActionPreference
  try {
    $ErrorActionPreference='Continue'
    $lines=@(& $kubectl @KubectlArgs 2>&1)
    $exitCode=$LASTEXITCODE
    $output=($lines | ForEach-Object { [string]$_ }) -join "`n"
    return [pscustomobject]@{exitCode=[int]$exitCode;output=$output}
  } catch {
    return [pscustomobject]@{exitCode=if($null -ne $LASTEXITCODE){[int]$LASTEXITCODE}else{1};output=$_.Exception.Message}
  } finally {
    $ErrorActionPreference=$previousPreference
  }
}
function Get-ChaosLookup {
  $lookup=Invoke-KubectlCaptured @('-n',$Namespace,'get','stresschaos',$ChaosName,'-o','json')
  Resolve-E2ChaosLookup -ExitCode $lookup.exitCode -Output $lookup.output -ExpectedUid $uid
}
function Get-ChaosStatus { try { $c=KJson @('-n',$Namespace,'get','stresschaos',$ChaosName,'-o','json'); $injected=@($c.status.conditions|Where-Object{$_.type -in @('Injected','AllInjected') -and $_.status -eq 'True'}).Count -gt 0; [ordered]@{phase=$c.status.phase;injected=$injected;injectionCondition=if(@($c.status.conditions|Where-Object{$_.type -eq 'AllInjected' -and $_.status -eq 'True'}).Count){'AllInjected=True'}else{'Injected=True'};conditions=$c.status.conditions} } catch { $null } }
function Wait-Injected { for($i=0;$i-lt 6;$i++){ $s=Get-ChaosStatus;if($s){$run.chaos.status=$s};if($s -and $s.injected){return $true};Start-Sleep 1 };return $false }
function Publish-E2Sample($reading) {
  $script:lastPublishOk=$false; $script:lastPublishAt=$null
  if($reading -and (-not [double]::IsNaN([double]$reading.memoryBytes) -and -not [double]::IsInfinity([double]$reading.memoryBytes) -and -not [double]::IsNaN([double]$reading.memoryRatio) -and -not [double]::IsInfinity([double]$reading.memoryRatio)) -and [double]$reading.memoryBytes -gt 0 -and [double]$reading.memoryRatio -gt 0 -and [double]$reading.memoryRatio -le 1) {
    try {
      Invoke-RestMethod ($engine+'/api/recovery/e2/sample') -Method Post -ContentType 'application/json' -Body (@{memoryBytes=[double]$reading.memoryBytes;memoryRatio=[double]$reading.memoryRatio}|ConvertTo-Json) -TimeoutSec 5 | Out-Null
      $script:lastPublishAt=[DateTimeOffset]::UtcNow; $script:lastPublishOk=$true
    } catch { Add-Evidence 'metrics' ('E2 sample publish unavailable: '+$_.Exception.Message) }
  }
}
function Eval([bool]$execute,[string]$phase) { try{$requestedAt=IstNow;$r=Invoke-RestMethod ($engine+'/api/recovery/evaluate/adaptive-inventory-service?execute='+$execute.ToString().ToLower()+'&profile=e2-memory') -Method Post -TimeoutSec 8;$responseAt=IstNow;$run.engineEvaluations+=[ordered]@{timestamp=$responseAt;requestedAt=$requestedAt;phase=$phase;execute=$execute;decision=$r.decision;reason=$r.reason;actionVerified=$r.actionVerified;response=$r};Save-Run;return $r}catch{$run.engineEvaluations+=[ordered]@{timestamp=IstNow;phase=$phase;execute=$execute;error=$_.Exception.Message};Save-Run;return $null} }
function Read-Memory([string]$phase,$cleanupVerifiedAt=$null) {
  $metrics=KJson @('get','--raw',"/apis/metrics.k8s.io/v1beta1/namespaces/$Namespace/pods")
  $pods=KJson @('-n',$Namespace,'get','pods','-l','app.kubernetes.io/name=adaptive-inventory-service','-o','json')
  $limitRaw=[string](Resources (Get-Deployment)).memoryLimit
  $limit=if($limitRaw -match '^(\d+)Mi$'){[double]$Matches[1]*1MB}elseif($limitRaw -match '^(\d+)Gi$'){[double]$Matches[1]*1GB}else{0}
  $sample=Get-E2MemorySample -Metrics $metrics -Pods $pods -LimitBytes $limit -PreviousSample $script:lastMetricsSample
  if(-not $sample.available){$run.preflight.lastSampleError=$sample.reason;return $null}
  if($null -ne $cleanupVerifiedAt){
    $fresh=Test-E2PostCleanupSample -Sample $sample -CleanupVerifiedAt ([DateTimeOffset]$cleanupVerifiedAt)
    if(-not $fresh.passed){$run.graph.reason=$fresh.reason;return $null}
  }
  $script:lastMetricsSample=$sample
  $reading=[ordered]@{available=$true;timestamp=$sample.timestamp;metricsTimestamp=$sample.metricsTimestamp;phase=$phase;pod=$sample.pod;podUid=$sample.podUid;container=$sample.container;memoryRatio=$sample.memoryRatio;memoryBytes=$sample.memoryBytes;raw=$sample.raw;limitBytes=$sample.limitBytes;window=$sample.window}
  $run.memoryReadings+=$reading
  Publish-E2Sample $reading
  return $reading
}
function Wait-E2PostCleanupGraph([DateTimeOffset]$cleanupVerifiedAt) {
  $run.graph.status='GRAPH_INCOMPLETE'
  $run.graph.reason='No fresh post-cleanup Metrics API sample was observed within 90 seconds'
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds(90)
  $reading=$null
  while([DateTimeOffset]::UtcNow -lt $deadline){
    try {$reading=Read-Memory 'after' $cleanupVerifiedAt} catch {$run.graph.reason='Post-cleanup Metrics API read failed: '+$_.Exception.Message}
    if($reading){break}
    Save-Run
    Start-Sleep -Seconds 5
  }
  if(-not $reading){return}
  $run.graph.sourceTimestamp=$reading.metricsTimestamp; $run.graph.sourceWindow=$reading.window
  $run.graph.podUid=$reading.podUid; $run.graph.memoryBytes=$reading.memoryBytes; $run.graph.memoryRatio=$reading.memoryRatio
  if(-not $script:lastPublishOk){$run.graph.reason='Fresh post-cleanup sample was captured, but the E2 exporter rejected publication';Save-Run;return}
  $run.graph.publishedAt=$script:lastPublishAt.ToOffset([TimeSpan]::FromHours(5.5)).ToString('yyyy-MM-ddTHH:mm:sszzz')
  $run.graph.reason='Fresh sample published; waiting for project Prometheus to scrape both E2 gauges'
  Save-Run
  $scrapeDeadline=[DateTimeOffset]::UtcNow.AddSeconds(45)
  $metricSelector='{job="adaptive-recovery-engine-e2",project="resilient-microservices-adaptive-recovery"}'
  while([DateTimeOffset]::UtcNow -lt $scrapeDeadline){
    try {
      $bytes=Invoke-RestMethod ('http://127.0.0.1:19090/api/v1/query?query='+[uri]::EscapeDataString('adaptive_recovery_e2_memory_bytes'+$metricSelector)) -TimeoutSec 5
      $ratio=Invoke-RestMethod ('http://127.0.0.1:19090/api/v1/query?query='+[uri]::EscapeDataString('adaptive_recovery_e2_memory_ratio'+$metricSelector)) -TimeoutSec 5
      $scrape=Test-E2PrometheusScrape -BytesResponse $bytes -RatioResponse $ratio -PublishedAt $script:lastPublishAt -MemoryBytes $reading.memoryBytes -MemoryRatio $reading.memoryRatio
      $run.graph.reason=$scrape.reason
      if($scrape.passed){$run.graph.status='COMPLETE';$run.graph.scrapedAt=$scrape.scrapedAt;Save-Run;return}
    } catch {$run.graph.reason='Prometheus scrape query unavailable: '+$_.Exception.Message}
    Save-Run
    Start-Sleep -Seconds 5
  }
  $run.graph.reason='GRAPH_INCOMPLETE: '+$run.graph.reason
}
function Collect-E2Baseline {
  $samples=@()
  $deadline=[DateTimeOffset]::UtcNow.AddSeconds($BaselineTimeoutSeconds)
  while($samples.Count -lt $BaselineSamplesRequired -and [DateTimeOffset]::UtcNow -lt $deadline){
    $sample=Read-Memory 'before'
    if($sample){
      $samples+=,$sample
      $run.preflight.samples+=,[ordered]@{metricsTimestamp=$sample.metricsTimestamp;window=$sample.window;pod=$sample.pod;podUid=$sample.podUid;memoryRatio=$sample.memoryRatio;raw=$sample.raw}
      Save-Run
    }
    if($samples.Count -lt $BaselineSamplesRequired){Start-Sleep -Seconds $BaselinePollSeconds}
  }
  return $samples
}
try {
  $d=Get-Deployment;$baseline=Resources $d;$run.resources.before=$baseline;$run.readiness.before=Get-Readiness $d
  if(-not $CheckOnly){
    $configured=($baseline.cpuRequest -eq '100m' -and $baseline.cpuLimit -eq '500m' -and $baseline.memoryRequest -eq '256Mi' -and $baseline.memoryLimit -eq '512Mi')
    if(-not $configured -or -not $run.readiness.before){
      $assessment=[pscustomobject]@{passed=$false;reason='Inventory is not Ready at the configured 100m/500m CPU and 256Mi/512Mi memory baseline'}
    } else {
      $baselineSamples=@(Collect-E2Baseline)
      $assessment=Test-E2BaselineSamples -Samples $baselineSamples -GuardRatio $BaselineGuardRatio -Required $BaselineSamplesRequired
      if($baselineSamples.Count){$run.preflight.baselineMemoryRatio=$baselineSamples[-1].memoryRatio}
      if(-not $assessment.passed -and $baselineSamples.Count -lt $BaselineSamplesRequired -and $run.preflight.lastSampleError){$assessment.reason+="; last Metrics API error: $($run.preflight.lastSampleError)"}
    }
    $run.preflight.blocked=(-not $assessment.passed)
    $run.preflight.reason=$assessment.reason
    if($run.preflight.blocked){
      $run.result='PREFLIGHT_BLOCKED';$run.experimentOutcome='NOT_STARTED'
      Add-Evidence 'preflight' ("Blocked before Chaos creation and Engine evaluation: " + $assessment.reason + ". E2 was not injected.")
    }
  }
  Save-Run
  if($CheckOnly){K @('apply','--dry-run=server','-f',$manifest);$run.result='CHECK_ONLY_PASS'} elseif(-not $run.preflight.blocked) {
    K @('apply','-f',$manifest);$created=$true;$run.chaos.created=$true;$chaos=KJson @('-n',$Namespace,'get','stresschaos',$ChaosName,'-o','json');$uid=$chaos.metadata.uid;$run.chaos.uid=$uid
    if(Wait-Injected){$run.timestamps.T0=IstNow;Add-Evidence 'T0' 'Chaos Mesh StressChaos status.conditions[type=Injected,status=True] after apply.'}else{Add-Evidence 'T0' 'Chaos resource existed but Injected=True was not observed.'};Save-Run
    $above=0;$executed=$false;$attempted=$false;$actionResponse=$null
    $triggerCpu=$null;$actionVerified=$false;$actionObservationPending=$false;$actionIteration=-1
    for($i=0;$i-lt $Samples;$i++){Start-Sleep $SampleIntervalSeconds;$reading=Read-Memory 'during';if($reading -and $reading.memoryRatio -ge $SafetyCapRatio){$run.safetyCapReached=$true;$run.result='SAFETY_CAP_REACHED';$run.experimentOutcome='FAILED_SAFE_CAP';Add-Evidence 'safetyCap' 'Measured memory ratio reached the configured safety cap; sampling stopped for cleanup.';Save-Run;break};if($reading){if($reading.memoryRatio-ge$MemoryThresholdRatio){$above++;if(-not$run.timestamps.T1){$run.timestamps.T1=$reading.timestamp;$t1Memory=$reading.memoryRatio;Add-Evidence 'T1' "First Kubernetes Metrics API sample $($reading.raw) ($($reading.memoryRatio) memory ratio) met the configured threshold.";Save-Run}}else{$above=0}};$null=Eval $false 'during';if($above-ge$SustainedSamples-and-not$attempted){$attempted=$true;$actionIteration=$i;$triggerCpu=if($reading){$reading.memoryRatio}else{$null};$actionResponse=Eval $true 'actuator';if($actionResponse-and$actionResponse.decision-eq'INCREASE_MEMORY'){$executed=$true;if(-not$run.timestamps.T2){$run.timestamps.T2=$run.engineEvaluations[-1].timestamp;Add-Evidence 'T2' 'Actual execute=true Engine INCREASE_MEMORY response timestamp; preview evaluations and CONTINUE responses are excluded.';Save-Run}};if($actionResponse-and$actionResponse.decision-eq'INCREASE_MEMORY'){$during=Resources (Get-Deployment);$run.resources.during+=$during;$appliedReady=($during.memoryRequest-ne$baseline.memoryRequest-or$during.memoryLimit-ne$baseline.memoryLimit)-and(Get-Readiness (Get-Deployment));if($appliedReady){$run.timestamps.T3=IstNow;Add-Evidence 'T3' 'Kubernetes Deployment shows increased memory resources and Inventory is Ready.';Save-Run;$actionVerified=[bool]$actionResponse.actionVerified;$actionObservationPending=$actionVerified}}};Save-Run}
    if($executed){$run.result='ACTION_REQUESTED';$run.experimentOutcome='MEMORY_ACTION_REQUESTED'}else{$run.result='NOT_TRIGGERED';$run.experimentOutcome='NOT_TRIGGERED';$run.thresholdNotSustained=($above -gt 0 -and $above -lt $SustainedSamples);if($run.thresholdNotSustained){Add-Evidence 'threshold' "Threshold not sustained: $above of $SustainedSamples required consecutive samples were above $MemoryThresholdRatio memory ratio.";Save-Run}}
  }
} catch {$run.result='FAILED';$run.cleanup.error=$_.Exception.Message;throw}
finally {
  $run.cleanup.attempted=$true
  $deletionRequested=$false; $deleteAccepted=$false; $deletionOutcome='not attempted'; $chaosAbsent=$false; $chaosError=$null
  $baselineVerified=$false; $rolloutVerified=$false; $readinessVerified=$false; $restoreError=$null

  if($CheckOnly){
    $run.graph.status='Not applicable — no live fault was created'
    if($baseline){$run.resources.after=$baseline;$run.readiness.after=$run.readiness.before;$run.cleanup.baselineVerified=$true;$run.cleanup.readinessVerified=($run.readiness.before -eq $true)}
    $null=Complete-E2Cleanup -Run $run -DeletionRequested $false -DeleteCommandAccepted $false -DeletionOutcome 'not applicable — no live fault was created' -ChaosAbsenceVerified $false -BaselineVerified ([bool]$run.cleanup.baselineVerified) -RolloutVerified $false -ReadinessVerified ([bool]$run.cleanup.readinessVerified) -VerifiedAt (IstNow) -CheckOnly
  } else {
    # Fault cleanup and baseline restoration are independent.  A NotFound
    # lookup is parsed as absence; its stderr is never allowed to skip restore.
    try {
      $lookup=Get-ChaosLookup
      if($lookup.state -eq 'Absent'){
        $chaosAbsent=$true
        $deletionOutcome='already absent; deletion not needed'
      } elseif($lookup.state -eq 'PresentOwned') {
        if($created -and $uid -and $lookup.uid -eq $uid){
          $deletionRequested=$true
          $run.chaos.deletionRequested=$true
          $run.cleanup.deletionRequested=$true
          Save-Run
          $delete=Invoke-KubectlCaptured @('delete','stresschaos',$ChaosName,'-n',$Namespace,'--wait=true')
          $deleteAccepted=($delete.exitCode -eq 0)
          $deletionOutcome=if($deleteAccepted){'delete command accepted'}else{"delete command failed (exit $($delete.exitCode)): $($delete.output)"}
          # Independently poll for absence; NotFound here is an expected,
          # successful observation, not an exceptional cleanup failure.
          for($i=0;$i -lt 12;$i++){
            $afterLookup=Get-ChaosLookup
            if($afterLookup.state -eq 'Absent'){$chaosAbsent=$true;break}
            if($afterLookup.state -ne 'PresentOwned'){if($afterLookup.state -eq 'PresentOther'){$chaosError='Chaos name is now occupied by a different UID; left untouched'}else{$chaosError=$afterLookup.reason};break}
            Start-Sleep -Milliseconds 500
          }
          if($chaosAbsent){$deletionOutcome+='; absence independently verified'}
          elseif(-not $chaosError){$chaosError='Chaos object remained present after bounded absence verification'}
        } else {
          $deletionOutcome='UID ownership could not be confirmed; object was not deleted'
          $chaosError='Live Chaos object was not proven to be created by this run; left untouched'
        }
      } elseif($lookup.state -eq 'PresentOther') {
        $deletionOutcome='live UID mismatch; object was not deleted'
        $chaosError='Live Chaos UID does not match this run; left untouched'
      } else {
        $deletionOutcome='Chaos lookup failed; deletion not attempted'
        $chaosError=$lookup.reason
      }
    } catch { $deletionOutcome='Chaos cleanup check failed'; $chaosError=$_.Exception.Message }

    # Always attempt restoration, even if lookup/delete/status verification
    # failed.  Do not patch when the exact saved baseline is already live.
    if($baseline){
      try {
        $current=Get-Deployment; $currentResources=Resources $current
        $diff=($currentResources.cpuRequest -ne $baseline.cpuRequest -or $currentResources.cpuLimit -ne $baseline.cpuLimit -or $currentResources.memoryRequest -ne $baseline.memoryRequest -or $currentResources.memoryLimit -ne $baseline.memoryLimit)
        if($diff){
          K @('set','resources','deployment','adaptive-inventory-service','-n',$Namespace,'-c','adaptive-inventory-service',"--requests=cpu=$($baseline.cpuRequest),memory=$($baseline.memoryRequest)","--limits=cpu=$($baseline.cpuLimit),memory=$($baseline.memoryLimit)")
        }
        K @('rollout','status','deployment/adaptive-inventory-service','-n',$Namespace,'--timeout=180s')
        $rolloutVerified=$true
        $restored=Get-Deployment; $after=Resources $restored
        $run.resources.after=$after
        $readinessVerified=Get-Readiness $restored
        $run.readiness.after=$readinessVerified
        $baselineVerified=($after.cpuRequest -eq $baseline.cpuRequest -and $after.cpuLimit -eq $baseline.cpuLimit -and $after.memoryRequest -eq $baseline.memoryRequest -and $after.memoryLimit -eq $baseline.memoryLimit)
        if(-not $baselineVerified){$restoreError='Live Deployment resources do not match the exact saved baseline'}
        elseif(-not $readinessVerified){$restoreError='Inventory Deployment did not return Ready after rollout verification'}
      } catch { $restoreError=$_.Exception.Message }
    } else { $restoreError='Saved Inventory baseline is unavailable; exact restoration cannot be verified' }

    $priorError=[string]$run.cleanup.error
    $cleanupErrors=@(@($priorError,$chaosError,$restoreError)|Where-Object{$_})
    if($cleanupErrors.Count){$run.cleanup.error=$cleanupErrors -join '; '}
    $run.chaos.deletionRequested=$deletionRequested
    $run.chaos.deletionOutcome=$deletionOutcome
    $run.chaos.absenceVerified=$chaosAbsent
    $run.cleanup.deletionRequested=$deletionRequested
    $run.cleanup.deletionOutcome=$deletionOutcome
    $run.cleanup.absenceVerified=$chaosAbsent
    $run.cleanup.baselineVerified=$baselineVerified
    $run.cleanup.rolloutVerified=$rolloutVerified
    $run.cleanup.readinessVerified=$readinessVerified
    Save-Run

    # A cleanup verdict is independent of later Metrics API/Prometheus telemetry.
    $cleanupPass=($chaosAbsent -and $baselineVerified -and $rolloutVerified -and $readinessVerified)
    $verifiedAt=IstNow
    $null=Complete-E2Cleanup -Run $run -DeletionRequested $deletionRequested -DeleteCommandAccepted $deleteAccepted -DeletionOutcome $deletionOutcome -ChaosAbsenceVerified $chaosAbsent -BaselineVerified $baselineVerified -RolloutVerified $rolloutVerified -ReadinessVerified $readinessVerified -VerifiedAt $verifiedAt -ErrorMessage $run.cleanup.error
    if($cleanupPass){
      $markers=@('T0','T1','T2','T3','T5'); $valid=$true; $last=$null
      foreach($marker in $markers){$value=$run.timestamps[$marker];if(-not$value){$valid=$false;break};$parsed=[DateTimeOffset]::Parse($value);if($last -and $parsed -lt $last){$valid=$false;break};$last=$parsed}
      if($valid){$run.timestamps.timeToStableState=([DateTimeOffset]::Parse($run.timestamps.T5)-[DateTimeOffset]::Parse($run.timestamps.T0)).ToString()}
      else{$run.timestamps.timeToStableState=$null;Add-Evidence 'timeToStableState' 'Unavailable because one or more required T0-T3 or T5 markers is missing or out of order.'}
    }
    Save-Run
    if($cleanupPass){
      try {Wait-E2PostCleanupGraph ([DateTimeOffset]::Parse($verifiedAt))}
      catch {$run.graph.status='GRAPH_INCOMPLETE';$run.graph.reason='Post-cleanup telemetry failed: '+$_.Exception.Message}
    } else {$run.graph.status='GRAPH_INCOMPLETE';$run.graph.reason='Cleanup was not independently verified; no post-cleanup graph point was published'}
  }

  Save-Run
  if($run.cleanup.restoreVerify){'RESTORE_VERIFY=PASS'}else{'RESTORE_VERIFY=FAIL_OR_UNAVAILABLE'}
  "RUN_RECORD=$runPath"
}
