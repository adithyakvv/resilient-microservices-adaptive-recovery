$KubectlPath = if ($env:KUBECTL_BIN) { $env:KUBECTL_BIN } else { (Get-Command kubectl -ErrorAction Stop).Source }
$Namespace = 'resilient-microservices-adaptive-recovery'
$DeploymentName = 'adaptive-inventory-service'
$ContainerName = 'adaptive-inventory-service'

function Invoke-Kubectl {
    param([string[]]$Arguments)

    $output = & $script:KubectlPath @Arguments 2>&1
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        throw "kubectl failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

$chaosAbsent = $true
$baselineMatches = $false

try {
    if (-not (Test-Path $KubectlPath)) {
        throw "kubectl was not found at: $KubectlPath"
    }

    foreach ($chaosName in @(
        'adaptive-inventory-e1-cpu',
        'adaptive-inventory-e2-memory'
    )) {
        $chaosOutput = @(
            Invoke-Kubectl -Arguments @(
                '-n', $Namespace,
                'get', 'stresschaos', $chaosName,
                '--ignore-not-found', '-o', 'name'
            )
        )

        $found = @(
            $chaosOutput | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            }
        ).Count -gt 0

        if ($found) {
            "Chaos resource ${chaosName}: PRESENT"
            $chaosAbsent = $false
        } else {
            "Chaos resource ${chaosName}: ABSENT"
        }
    }

    $deploymentOutput = @(
        Invoke-Kubectl -Arguments @(
            '-n', $Namespace,
            'get', 'deployment', $DeploymentName, '-o', 'json'
        )
    )
    $deployment = ($deploymentOutput -join [Environment]::NewLine) |
        ConvertFrom-Json

    $container = $deployment.spec.template.spec.containers |
        Where-Object { $_.name -eq $ContainerName } |
        Select-Object -First 1

    $desired = [int]$deployment.spec.replicas
    $ready = 0
    if ($null -ne $deployment.status.readyReplicas) {
        $ready = [int]$deployment.status.readyReplicas
    }

    $cpuRequest = [string]$container.resources.requests.cpu
    $cpuLimit = [string]$container.resources.limits.cpu
    $memoryRequest = [string]$container.resources.requests.memory
    $memoryLimit = [string]$container.resources.limits.memory

    [pscustomobject]@{
        DesiredReplicas = $desired
        ReadyReplicas   = $ready
        CpuRequest      = $cpuRequest
        CpuLimit        = $cpuLimit
        MemoryRequest   = $memoryRequest
        MemoryLimit     = $memoryLimit
    }

    $baselineMatches = (
        $null -ne $container -and
        $desired -eq 1 -and
        $ready -eq 1 -and
        $cpuRequest -eq '100m' -and
        $cpuLimit -eq '500m' -and
        $memoryRequest -eq '256Mi' -and
        $memoryLimit -eq '512Mi'
    )
}
catch {
    Write-Host "Preflight check error: $($_.Exception.Message)" -ForegroundColor Red
}

if ($chaosAbsent -and $baselineMatches) {
    Write-Host 'E2 PREFLIGHT: PASS — safe to run once from the GUI' -ForegroundColor Green
} else {
    Write-Host 'E2 PREFLIGHT: FAIL — do not run E2; share this output with Codex' -ForegroundColor Red
}
