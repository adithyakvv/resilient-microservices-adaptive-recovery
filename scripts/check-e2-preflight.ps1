$kubectl = if ($env:KUBECTL_BIN) { $env:KUBECTL_BIN } else { (Get-Command kubectl -ErrorAction Stop).Source }
$ns = 'resilient-microservices-adaptive-recovery'

$chaos = @(& $kubectl -n $ns get stresschaos adaptive-inventory-e2-memory --ignore-not-found -o name)
if ($chaos.Count -eq 0) {
    'E2 Chaos: ABSENT'
} else {
    "E2 Chaos: PRESENT ($($chaos -join ', '))"
}

$d = & $kubectl -n $ns get deployment adaptive-inventory-service -o json | ConvertFrom-Json
$c = $d.spec.template.spec.containers |
    Where-Object { $_.name -eq 'adaptive-inventory-service' } |
    Select-Object -First 1

$result = [pscustomobject]@{
    DesiredReplicas = $d.spec.replicas
    ReadyReplicas   = $d.status.readyReplicas
    MemoryRequest   = $c.resources.requests.memory
    MemoryLimit     = $c.resources.limits.memory
}
$result

if ($chaos.Count -eq 0 -and
    $d.spec.replicas -eq 1 -and $d.status.readyReplicas -eq 1 -and
    $c.resources.requests.memory -eq '256Mi' -and
    $c.resources.limits.memory -eq '512Mi') {
    'E2 PREFLIGHT: PASS — safe to run once from the GUI'
} else {
    'E2 PREFLIGHT: FAIL — do not run; share this output with Codex'
}
