function Get-E2PreparationDecision {
  param($Assessment, [object[]]$Samples, [double]$GuardRatio = 0.55, [int]$Required = 3)
  if ($Assessment.passed) {
    return [pscustomobject]@{ status='Ready'; restartAllowed=$false; reason=$Assessment.reason }
  }
  if (@($Samples).Count -ne $Required) {
    return [pscustomobject]@{ status='Blocked'; restartAllowed=$false; reason=$Assessment.reason }
  }
  $first=$Samples[0];$previous=[DateTimeOffset]::MinValue
  foreach($sample in $Samples){
    $source=[DateTimeOffset]::MinValue
    if(-not$sample.available -or -not$sample.window -or -not$sample.podUid -or
       $sample.podUid -ne $first.podUid -or $sample.pod -ne $first.pod -or
       -not[DateTimeOffset]::TryParse([string]$sample.metricsTimestamp,[ref]$source) -or
       $source -le $previous){
      return [pscustomobject]@{ status='Blocked'; restartAllowed=$false; reason='Baseline samples are stale, duplicated, or from different Inventory pods' }
    }
    $previous=$source
  }
  $above=@($Samples | Where-Object { $_.available -and [double]$_.memoryRatio -ge $GuardRatio })
  if ($above.Count -eq 0) {
    return [pscustomobject]@{ status='Blocked'; restartAllowed=$false; reason=$Assessment.reason }
  }
  return [pscustomobject]@{ status='Blocked'; restartAllowed=$true; reason="Baseline memory is at or above $GuardRatio guard; one Inventory-only maintenance restart may be attempted after safety checks" }
}

function Test-E2MaintenanceReplacement {
  param([string]$OriginalUid, $ReplacementPod, [bool]$HealthUp)
  $newUid=[string]$ReplacementPod.metadata.uid
  $ready=@($ReplacementPod.status.containerStatuses | Where-Object { $_.name -eq 'adaptive-inventory-service' -and $_.ready -eq $true }).Count -eq 1
  $passed=($OriginalUid -and $newUid -and $newUid -ne $OriginalUid -and
           $ReplacementPod.status.phase -eq 'Running' -and $ready -and $HealthUp)
  [pscustomobject]@{ passed=[bool]$passed; originalUid=$OriginalUid; replacementUid=$newUid;
    reason=if($passed){'Different Inventory pod UID is Ready and Inventory health is UP'}else{'Different Ready Inventory pod UID and health UP were not both verified'} }
}
Export-ModuleMember -Function Get-E2PreparationDecision, Test-E2MaintenanceReplacement
