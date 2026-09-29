function Test-E1EnginePreflight {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$false)]$Response,
    [int]$RequiredPersistenceSamples = 3,
    [int]$MaximumAgeSeconds = 30,
    [DateTimeOffset]$Now = [DateTimeOffset]::Now
  )

  $blockers = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Response) {
    $blockers.Add('Engine response unavailable')
    return [pscustomobject]@{ passed=$false; blockers=@($blockers); response=$null }
  }

  [DateTimeOffset]$at = [DateTimeOffset]::MinValue
  if (-not $Response.at -or -not [DateTimeOffset]::TryParse([string]$Response.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) {
    $blockers.Add('at: missing or invalid Engine evaluation timestamp')
  } else {
    $age = ($Now - $at).TotalSeconds
    if ($age -lt -5 -or $age -gt $MaximumAgeSeconds) {
      $blockers.Add("at: Engine evaluation is stale or from the future (age=$([math]::Round($age,1))s; maximum=$MaximumAgeSeconds s)")
    }
  }

  if ($null -eq $Response.signals) {
    $blockers.Add('signals: Engine response has no signals object')
  } else {
    foreach ($name in @('cpu','memory','readiness','httpErrors','latency')) {
      $value = $Response.signals.$name
      $number = 0.0
      if ($null -eq $value -or $value -isnot [ValueType] -or $value -is [bool] -or -not [double]::TryParse([string]$value, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        $blockers.Add("signals.${name}: missing or non-finite numeric value")
      }
    }

    foreach ($name in @('cpu','memory','httpErrors','latency')) {
      $number = [double]::NaN
      if ([double]::TryParse([string]$Response.signals.$name, [ref]$number)) {
        if ($number -lt 0 -or ($name -eq 'memory' -and $number -gt 1)) {
          $blockers.Add("signals.${name}: value outside valid range ($number)")
        }
      }
    }

    $readiness = 0.0
    if ([double]::TryParse([string]$Response.signals.readiness, [ref]$readiness) -and $readiness -ne 1.0) {
      $blockers.Add("signals.readiness: expected 1, received $($Response.signals.readiness)")
    }

    foreach ($name in @('kubernetesHealthy','dependencyUp')) {
      if ($Response.signals.$name -isnot [bool] -or $Response.signals.$name -ne $true) {
        $blockers.Add("signals.${name}: expected true, received $($Response.signals.$name)")
      }
    }

    $persistence = 0
    if (-not [int]::TryParse([string]$Response.signals.persistenceSamples, [ref]$persistence) -or $persistence -lt $RequiredPersistenceSamples) {
      $blockers.Add("signals.persistenceSamples: expected at least $RequiredPersistenceSamples, received $($Response.signals.persistenceSamples)")
    }

    # Inventory has no outgoing dependency path. The Engine uses -1 for this
    # not-applicable field; dependencyUp remains the required health signal.
  }

  if ($Response.decision -eq 'FAIL_SAFE') {
    $reason = if ($Response.reason) { [string]$Response.reason } else { 'no reason supplied' }
    $blockers.Add("decision: Engine returned FAIL_SAFE ($reason)")
  }

  return [pscustomobject]@{ passed=($blockers.Count -eq 0); blockers=@($blockers); response=$Response }
}

function Invoke-E1PreflightGate {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Evaluate,
    [Parameter(Mandatory=$true)][scriptblock]$OnPass,
    [int]$RequiredPersistenceSamples = 3,
    [int]$MaximumAgeSeconds = 30,
    [DateTimeOffset]$Now = [DateTimeOffset]::Now
  )

  $response = & $Evaluate
  $check = Test-E1EnginePreflight -Response $response -RequiredPersistenceSamples $RequiredPersistenceSamples -MaximumAgeSeconds $MaximumAgeSeconds -Now $Now
  if ($check.passed) { $null = & $OnPass }
  return $check
}

Export-ModuleMember -Function Test-E1EnginePreflight,Invoke-E1PreflightGate
