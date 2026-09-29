$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'e2-baseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'e2-preparation.psm1') -Force
function Assert([bool]$condition,[string]$message){if(-not$condition){throw $message}}
$samples=@(0..2|ForEach-Object{[pscustomobject]@{available=$true;pod='adaptive-inventory-service-x';podUid='old';window='15s';metricsTimestamp=([DateTimeOffset]::Parse('2026-09-29T02:00:00Z').AddSeconds($_*15)).ToString('o');memoryRatio=0.49}})
$good=Test-E2BaselineSamples -Samples $samples -GuardRatio 0.55 -Required 3
$plan=Get-E2PreparationDecision -Assessment $good -Samples $samples
Assert ($good.passed -and $plan.status -eq 'Ready' -and -not$plan.restartAllowed) 'Three distinct below-guard samples need no restart'
$high=@($samples|ForEach-Object{$_.PSObject.Copy()});$high[2].memoryRatio=0.553
$blocked=Test-E2BaselineSamples -Samples $high -GuardRatio 0.55 -Required 3
$plan=Get-E2PreparationDecision -Assessment $blocked -Samples $high
Assert (-not$blocked.passed -and $plan.restartAllowed) 'Three distinct samples with a guard rejection may permit one restart'
$duplicate=@($samples|ForEach-Object{$_.PSObject.Copy()});$duplicate[2].metricsTimestamp=$duplicate[1].metricsTimestamp
$blocked=Test-E2BaselineSamples -Samples $duplicate -GuardRatio 0.55 -Required 3
$plan=Get-E2PreparationDecision -Assessment $blocked -Samples $duplicate
Assert (-not$blocked.passed -and -not$plan.restartAllowed) 'Duplicate timestamps must block without restart'
$duplicate[2].memoryRatio=0.553
$blocked=Test-E2BaselineSamples -Samples $duplicate -GuardRatio 0.55 -Required 3
$plan=Get-E2PreparationDecision -Assessment $blocked -Samples $duplicate
Assert (-not$plan.restartAllowed) 'A high but duplicated timestamp must never authorize restart'
$pod=[pscustomobject]@{metadata=[pscustomobject]@{uid='new'};status=[pscustomobject]@{phase='Running';containerStatuses=@([pscustomobject]@{name='adaptive-inventory-service';ready=$true})}}
Assert ((Test-E2MaintenanceReplacement -OriginalUid 'old' -ReplacementPod $pod -HealthUp $true).passed) 'Different Ready UID and health UP must verify restart'
Assert (-not(Test-E2MaintenanceReplacement -OriginalUid 'new' -ReplacementPod $pod -HealthUp $true).passed) 'Same UID cannot verify restart'
Assert (-not(Test-E2MaintenanceReplacement -OriginalUid 'old' -ReplacementPod $pod -HealthUp $false).passed) 'Health DOWN cannot verify restart'
$script=Get-Content (Join-Path $PSScriptRoot 'prepare-e2-inventory.ps1') -Raw
Assert ($script.Contains('Assert-NoExperiment;Assert-ChaosAbsent;Assert-InventoryBaseline') -and $script.Contains("if(-not`$plan.restartAllowed)")) 'Safety checks and blocked-no-restart branch are required'
Assert ($script.Contains("`$status.restart.count=1") -and $script.Contains("K @('delete','pod',`$old.metadata.name,'--wait=false')")) 'Exactly one named Inventory deletion is permitted'
Assert ($script.Contains('svc/adaptive-inventory-service') -and $script.Contains('18082:8082') -and $script.Contains('Get-CimInstance Win32_Process')) 'Health checks must use a verified Inventory-only forward'
Assert (-not$script.Contains("run-e2-inventory-memory.ps1") -and -not$script.Contains("apply','-f")) 'Preparation must not launch E2 or inject Chaos'
'E2_PREPARATION_MOCKED_PATHS=PASS'
