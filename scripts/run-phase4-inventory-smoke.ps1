param(
    [string] $Namespace = "resilient-microservices-adaptive-recovery",
    [string] $ChaosName = "adaptive-inventory-smoke"
)

$ErrorActionPreference = "Stop"
$uid = $null
$created = $false

function K([string[]] $KubectlArgs) {
    & kubectl @KubectlArgs
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed: $($KubectlArgs -join ' ')" }
}

try {
    $baseline = kubectl get deployment adaptive-inventory-service -n $Namespace -o jsonpath='{.status.readyReplicas}'
    if ($baseline -ne "1") { throw "Inventory baseline is not Ready (readyReplicas=$baseline)" }

    K @("apply", "-f", "infrastructure/chaos/phase4-inventory-smoke.yaml")
    $created = $true
    $uid = kubectl get podchaos $ChaosName -n $Namespace -o jsonpath='{.metadata.uid}'
    Write-Output "CHAOS_NAME=$ChaosName"
    Write-Output "CHAOS_UID=$uid"

    Start-Sleep -Seconds 5
    $active = kubectl get podchaos $ChaosName -n $Namespace -o jsonpath='{.status.experiment}'
    Write-Output "CHAOS_STATUS=$active"
    Start-Sleep -Seconds 20
}
finally {
    if ($created) {
        $currentUid = kubectl get podchaos $ChaosName -n $Namespace -o jsonpath='{.metadata.uid}' 2>$null
        if ($currentUid -eq $uid) {
            K @("delete", "podchaos", $ChaosName, "-n", $Namespace, "--wait=true")
            Write-Output "CLEANUP=deleted $ChaosName uid=$uid"
        } else {
            Write-Output "CLEANUP=blocked identity mismatch; expected=$uid actual=$currentUid"
        }
    }
    K @("rollout", "status", "deployment/adaptive-inventory-service", "-n", $Namespace, "--timeout=180s")
    $ready = kubectl get deployment adaptive-inventory-service -n $Namespace -o jsonpath='{.status.readyReplicas}'
    Write-Output "BASELINE_READY_REPLICAS=$ready"
    if ($ready -ne "1") { throw "Inventory did not return to baseline Ready state" }
}
