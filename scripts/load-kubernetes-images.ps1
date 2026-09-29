param(
    [string] $Tag = "phase2",
    [string[]] $Images = @(
        "adaptive-product-service",
        "adaptive-inventory-service",
        "adaptive-order-service"
    )
)

$ErrorActionPreference = "Stop"
$kubectlPath = if ($env:KUBECTL_BIN) { $env:KUBECTL_BIN } else { "kubectl" }

$namespace = "resilient-microservices-adaptive-recovery"
$loaderPod = "adaptive-image-loader"
$images = $Images
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("adaptive-$Tag-images-" + [guid]::NewGuid())
$originalLocation = Get-Location

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Command,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE"
    }
}

try {
    Set-Location $repoRoot
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

    Invoke-Checked $kubectlPath apply -f infrastructure/kubernetes/namespace.yaml
    Invoke-Checked $kubectlPath apply -n $namespace -f infrastructure/kubernetes/registry.yaml
    Invoke-Checked $kubectlPath rollout status deployment/adaptive-image-registry -n $namespace --timeout=180s

    foreach ($image in $images) {
        Invoke-Checked docker image inspect "${image}:$Tag"
        Invoke-Checked docker image save --output (Join-Path $temporaryDirectory "${image}.tar") "${image}:$Tag"
    }

    Invoke-Checked $kubectlPath delete pod $loaderPod -n $namespace --ignore-not-found=true --wait=true
    Invoke-Checked $kubectlPath run $loaderPod -n $namespace --image=quay.io/skopeo/stable:latest --restart=Never --command -- sleep 3600
    Invoke-Checked $kubectlPath wait --for=condition=Ready "pod/$loaderPod" -n $namespace --timeout=180s

    Push-Location $temporaryDirectory
    try {
        foreach ($image in $images) {
            Invoke-Checked $kubectlPath cp ".\${image}.tar" "${namespace}/${loaderPod}:/tmp/${image}.tar"
            & $kubectlPath exec $loaderPod -n $namespace -- sh -c "skopeo copy --format v2s2 --dest-tls-verify=false docker-archive:/tmp/${image}.tar docker://adaptive-image-registry:5000/${image}:$Tag"
            if ($LASTEXITCODE -ne 0) { throw "kubectl image import failed for $image" }
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    & $kubectlPath delete pod $loaderPod -n $namespace --ignore-not-found=true --wait=true | Out-Null
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
    Set-Location $originalLocation
}
