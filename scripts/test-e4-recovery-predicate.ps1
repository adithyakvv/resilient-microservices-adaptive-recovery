$ErrorActionPreference='Stop'
function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}
function Recovery-Verified($probes,[double]$threshold=500){
  $safe=@($probes|Where-Object {$_.available -and $_.status -eq 409 -and -not $_.orderPersisted})
  $good=@($safe|Where-Object {[double]$_.latencyMs -lt $threshold})
  return ($good.Count -eq 2 -and $safe.Count -eq 2 -and $probes[0].at -ne $probes[1].at)
}
$ok=@(
  [pscustomobject]@{available=$true;status=409;orderPersisted=$false;latencyMs=120;at='2026-09-27T10:00:00+05:30'},
  [pscustomobject]@{available=$true;status=409;orderPersisted=$false;latencyMs=140;at='2026-09-27T10:00:02+05:30'}
)
$high=@($ok[0],[pscustomobject]@{available=$true;status=409;orderPersisted=$false;latencyMs=700;at='2026-09-27T10:00:02+05:30'})
$same=@($ok[0],[pscustomobject]@{available=$true;status=409;orderPersisted=$false;latencyMs=140;at='2026-09-27T10:00:00+05:30'})
Assert (Recovery-Verified $ok) 'Two fresh post-restart probes below threshold should verify recovery.'
Assert (-not (Recovery-Verified $high)) 'A post-restart probe at/above threshold must fail recovery.'
Assert (-not (Recovery-Verified $same)) 'Repeated timestamp must not count as a fresh second probe.'
Write-Output 'E4_RECOVERY_PREDICATE_TEST=PASS'
