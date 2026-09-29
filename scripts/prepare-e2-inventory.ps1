param([switch]$CheckOnly)
$ErrorActionPreference='Stop'
$kubectl=if($env:KUBECTL_BIN){$env:KUBECTL_BIN}else{(Get-Command kubectl -ErrorAction Stop).Source}
$context='docker-desktop';$namespace='resilient-microservices-adaptive-recovery'
$root=Split-Path $PSScriptRoot -Parent
$statusPath=Join-Path $root 'reports\e2-preparation-status.json'
Import-Module (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'e2-preparation.psm1') -Force
$status=[ordered]@{
  kind='E2 preparation';running=$true;state='Preparing';phase='Starting';reason=$null
  checkOnly=[bool]$CheckOnly;willRestart='Only if three fresh samples fail the 0.55 guard and safety checks pass'
  restart=[ordered]@{attempted=$false;count=0;oldPod=$null;oldUid=$null;newPod=$null;newUid=$null;verified=$false;deleteOutput=$null;forwardPid=$null}
  baseline=[ordered]@{before=@();after=@();guardRatio=0.55;requiredFreshSamples=3;assessment=$null}
  safety=[ordered]@{noExperiment=$false;e1ChaosAbsent=$false;e2ChaosAbsent=$false;inventoryBaseline=$false;healthUp=$false}
  startedAt=([DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5))).ToString('o');finishedAt=$null
}
function Save-Status { $status|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $statusPath -Encoding UTF8 }
function K([string[]]$Arguments) {
  $output=(& $kubectl --context $context --namespace $namespace @Arguments | Out-String)
  if($LASTEXITCODE -ne 0){throw "kubectl failed: $($Arguments -join ' ')"}
  return $output
}
function KJson([string[]]$Arguments) { $text=K $Arguments; if(-not$text.Trim()){throw "Empty kubectl response: $($Arguments -join ' ')"};return $text|ConvertFrom-Json }
function Assert-NoExperiment {
  foreach($number in 1..6){
    $run=Invoke-RestMethod "http://127.0.0.1:18080/api/e$number/status" -TimeoutSec 8
    if($run.running){throw "E$number is running; Inventory preparation cannot restart it"}
    if($run.activeExperiment -and $run.activeExperiment.name -ne 'E2 preparation'){
      throw "Another experiment is active: $($run.activeExperiment.name)"
    }
  }
  $status.safety.noExperiment=$true;Save-Status
}
function Assert-ChaosAbsent {
  foreach($item in @(@('adaptive-inventory-e1-cpu','e1ChaosAbsent'),@('adaptive-inventory-e2-memory','e2ChaosAbsent'))){
    $found=K @('get','stresschaos',$item[0],'--ignore-not-found','-o','name')
    if(-not[string]::IsNullOrWhiteSpace($found)){throw "$($item[0]) StressChaos is present; no Inventory restart will be attempted"}
    $status.safety[$item[1]]=$true
  }
  Save-Status
}
function Get-Deployment { KJson @('get','deployment','adaptive-inventory-service','-o','json') }
function Assert-InventoryBaseline {
  $d=Get-Deployment
  $c=@($d.spec.template.spec.containers|Where-Object name -eq 'adaptive-inventory-service'|Select-Object -First 1)[0]
  if([int]$d.spec.replicas -ne 1 -or [int]$d.status.readyReplicas -ne 1 -or
     $c.resources.requests.cpu -ne '100m' -or $c.resources.limits.cpu -ne '500m' -or
     $c.resources.requests.memory -ne '256Mi' -or $c.resources.limits.memory -ne '512Mi'){
    throw 'Inventory is not 1/1 Ready at CPU 100m/500m and memory 256Mi/512Mi; no maintenance restart will be attempted'
  }
  $status.safety.inventoryBaseline=$true;Save-Status
}
function Get-ReadyPod {
  $pods=KJson @('get','pods','-l','app.kubernetes.io/name=adaptive-inventory-service','-o','json')
  $ready=@($pods.items|Where-Object{ -not $_.metadata.deletionTimestamp -and $_.status.phase -eq 'Running' -and
    @($_.status.containerStatuses|Where-Object{$_.name -eq 'adaptive-inventory-service' -and $_.ready -eq $true}).Count -eq 1 })
  if($ready.Count -ne 1){throw "Expected exactly one Ready Inventory pod; found $($ready.Count)"}
  return $ready[0]
}
function Collect-Baseline([string]$Phase) {
  $samples=@();$previous=$null;$deadline=[DateTimeOffset]::UtcNow.AddSeconds(65)
  while($samples.Count -lt 3 -and [DateTimeOffset]::UtcNow -lt $deadline){
    $metrics=KJson @('get','--raw',"/apis/metrics.k8s.io/v1beta1/namespaces/$namespace/pods")
    $pods=KJson @('get','pods','-l','app.kubernetes.io/name=adaptive-inventory-service','-o','json')
    $sample=Get-E2MemorySample -Metrics $metrics -Pods $pods -LimitBytes (512MB) -PreviousSample $previous
    if($sample.available){
      $samples+=,$sample;$previous=$sample
      $status.baseline[$Phase]=@($samples|ForEach-Object{
        [ordered]@{sourceTimestamp=$_.metricsTimestamp;window=$_.window;pod=$_.pod;podUid=$_.podUid;raw=$_.raw;memoryRatio=$_.memoryRatio}
      })
      $status.phase="Collecting $Phase baseline: $($samples.Count)/3 fresh samples";Save-Status
    } else {$status.phase="Waiting for fresh $Phase sample: $($sample.reason)";Save-Status}
    if($samples.Count -lt 3){Start-Sleep -Seconds 5}
  }
  return $samples
}
function Test-Health {
  try {
    $listeners=@(Get-NetTCPConnection -LocalPort 18082 -State Listen -ErrorAction SilentlyContinue|Group-Object OwningProcess|ForEach-Object{$_.Group[0]})
    if($listeners.Count -ne 1){return $false}
    $command=[string](Get-CimInstance Win32_Process -Filter "ProcessId = $($listeners[0].OwningProcess)" -ErrorAction Stop).CommandLine
    if($command -notmatch 'kubectl(\.exe)?' -or $command -notlike '*svc/adaptive-inventory-service*' -or
       $command -notlike '*18082:8082*'){return $false}
    $h=Invoke-RestMethod 'http://127.0.0.1:18082/actuator/health' -TimeoutSec 4
    return ($h.status -eq 'UP')
  }
  catch {return $false}
}
function Ensure-InventoryForward {
  if(Test-Health){return}
  $listeners=@(Get-NetTCPConnection -LocalPort 18082 -State Listen -ErrorAction SilentlyContinue|Group-Object OwningProcess|ForEach-Object{$_.Group[0]})
  if($listeners.Count -gt 1){throw 'Port 18082 has multiple listeners; refusing to replace any forward'}
  if($listeners.Count -eq 1){
    $id=[int]$listeners[0].OwningProcess
    $owned=@(if(Test-Path (Join-Path $root 'gui\.portforward-pids')){Get-Content (Join-Path $root 'gui\.portforward-pids')})
    $command=[string](Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction Stop).CommandLine
    if($id -notin @($owned|ForEach-Object{[int]$_}) -or $command -notmatch 'kubectl(\.exe)?' -or
       $command -notlike '*svc/adaptive-inventory-service*' -or $command -notlike '*18082:8082*'){
      throw 'Port 18082 is occupied by an unverified process; no process was stopped'
    }
    Stop-Process -Id $id -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    if(Get-NetTCPConnection -LocalPort 18082 -State Listen -ErrorAction SilentlyContinue){throw 'Port 18082 remained occupied after stopping the verified stale Inventory forward'}
  }
  $forward=Start-Process $kubectl -ArgumentList '--context',$context,'--namespace',$namespace,'port-forward','svc/adaptive-inventory-service','18082:8082' -PassThru -WindowStyle Hidden
  for($n=0;$n -lt 20;$n++){Start-Sleep -Seconds 1;if(Test-Health){break}}
  if(-not(Test-Health)){
    Stop-Process -Id $forward.Id -Force -ErrorAction SilentlyContinue
    throw 'Inventory health is not UP through port 18082 after a bounded forward retry'
  }
  Add-Content -LiteralPath (Join-Path $root 'gui\.portforward-pids') -Value $forward.Id
  $status.restart.forwardPid=$forward.Id;Save-Status
}
try {
  if(-not(Test-Path -LiteralPath $kubectl)){throw "Docker Desktop kubectl.exe not found: $kubectl"}
  Save-Status
  Assert-NoExperiment;Assert-ChaosAbsent;Assert-InventoryBaseline
  $before=@(Collect-Baseline 'before')
  $assessment=Test-E2BaselineSamples -Samples $before -GuardRatio 0.55 -Required 3
  $status.baseline.assessment=$assessment.reason
  $plan=Get-E2PreparationDecision -Assessment $assessment -Samples $before -GuardRatio 0.55 -Required 3
  if($plan.status -eq 'Ready'){
    $status.state='Ready';$status.reason='Three distinct fresh samples from the same Ready Inventory pod are below 0.55; no restart needed.'
    $status.willRestart='No';Save-Status
  } elseif($CheckOnly){
    $status.state='Blocked';$status.reason=$assessment.reason
    $status.willRestart=if($plan.restartAllowed){'May restart Inventory once after click if a fresh recheck remains above 0.55; CheckOnly did not restart'}else{'No — fresh evidence or safety preconditions are missing'}
    Save-Status
  } elseif(-not$plan.restartAllowed){
    $status.state='Blocked';$status.reason=$plan.reason;$status.willRestart='No — baseline evidence is incomplete';Save-Status
  } else {
    $status.phase='Checking safety before one Inventory maintenance restart';$status.willRestart='Yes — one Inventory pod replacement';Save-Status
    Assert-NoExperiment;Assert-ChaosAbsent;Assert-InventoryBaseline
    $old=Get-ReadyPod;$status.restart.oldPod=$old.metadata.name;$status.restart.oldUid=$old.metadata.uid;Save-Status
    if(-not(Test-Health)){Ensure-InventoryForward}
    if(-not(Test-Health)){throw 'Inventory health is not UP before maintenance restart'}
    $current=Get-ReadyPod
    if($current.metadata.uid -ne $old.metadata.uid){throw 'Inventory pod changed before restart; no pod was deleted'}
    $status.restart.attempted=$true;$status.restart.count=1;$status.phase='Replacing only the named Inventory pod';Save-Status
    $status.restart.deleteOutput=(K @('delete','pod',$old.metadata.name,'--wait=false')).Trim();Save-Status
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(150);$verified=$false
    while([DateTimeOffset]::UtcNow -lt $deadline){
      try {
        $d=Get-Deployment
        if([int]$d.status.readyReplicas -eq 1){
          $new=Get-ReadyPod
          if($new.metadata.uid -ne $old.metadata.uid){
            Ensure-InventoryForward
            $check=Test-E2MaintenanceReplacement -OriginalUid $old.metadata.uid -ReplacementPod $new -HealthUp (Test-Health)
            if($check.passed){$status.restart.newPod=$new.metadata.name;$status.restart.newUid=$new.metadata.uid;$status.restart.verified=$true;$status.safety.healthUp=$true;$verified=$true;Save-Status;break}
          }
        }
      } catch { $status.phase="Waiting for different Ready pod: $($_.Exception.Message)";Save-Status }
      Start-Sleep -Seconds 3
    }
    if(-not$verified){throw 'Inventory replacement did not reach a different Ready UID with health UP within 150 seconds'}
    Assert-InventoryBaseline;Assert-ChaosAbsent
    $after=@(Collect-Baseline 'after')
    $again=Test-E2BaselineSamples -Samples $after -GuardRatio 0.55 -Required 3
    $status.baseline.assessment=$again.reason
    if($again.passed){$status.state='Ready';$status.reason='One Inventory maintenance restart verified; three distinct fresh baseline samples are below 0.55.'}
    else{$status.state='Blocked';$status.reason="After one verified restart: $($again.reason). No second restart will be attempted."}
    Save-Status
  }
} catch {
  $status.state='Blocked';$status.reason=$_.Exception.Message;Save-Status
} finally {
  $status.running=$false;$status.phase='Finished';$status.finishedAt=([DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(5.5))).ToString('o')
  Save-Status
  "E2_PREPARATION=$($status.state) -- $($status.reason)"
  "INVENTORY_RESTART_COUNT=$($status.restart.count)"
}
if($status.state -eq 'Blocked'){exit 2}
