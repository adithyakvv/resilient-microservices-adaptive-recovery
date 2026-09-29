<##
Read-only check of the listeners managed by start-demo-gui.ps1.
Compatible with Windows PowerShell 5.1.  The checker never starts/stops a
process or changes Kubernetes state.
##>
param()

$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$expected = @(
    [ordered]@{ Kind='Kubernetes port-forward'; Service='adaptive-product-service'; LocalPort=18081; TargetPort=8081; Match='svc/adaptive-product-service' },
    [ordered]@{ Kind='Kubernetes port-forward'; Service='adaptive-inventory-service'; LocalPort=18082; TargetPort=8082; Match='svc/adaptive-inventory-service' },
    [ordered]@{ Kind='Kubernetes port-forward'; Service='adaptive-order-service'; LocalPort=18083; TargetPort=8083; Match='svc/adaptive-order-service' },
    [ordered]@{ Kind='Kubernetes port-forward'; Service='adaptive-recovery-prometheus'; LocalPort=19090; TargetPort=9090; Match='svc/adaptive-recovery-prometheus' },
    [ordered]@{ Kind='Kubernetes port-forward'; Service='adaptive-recovery-grafana'; LocalPort=13000; TargetPort=3000; Match='svc/adaptive-recovery-grafana' },
    [ordered]@{ Kind='Local GUI'; Service='gui/server.py'; LocalPort=18080; TargetPort='local'; Match='gui/server.py' },
    [ordered]@{ Kind='Local Recovery Engine'; Service='recovery-engine JAR'; LocalPort=8090; TargetPort='local'; Match='recovery-engine-0.1.0-SNAPSHOT.jar' }
)

function Get-ProcessCommandLine([int]$ProcessId) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
    if ($p) { return [string]$p.CommandLine }
    return ''
}

function Test-ExpectedListener($item) {
    try { $connections = @(Get-NetTCPConnection -LocalPort $item.LocalPort -State Listen -ErrorAction Stop | Group-Object OwningProcess | ForEach-Object { $_.Group[0] }) } catch { $connections = @() }
    if (-not $connections) {
        return [pscustomobject]@{Status='NOT RUNNING';Kind=$item.Kind;Service=$item.Service;LocalPort=$item.LocalPort;TargetPort=$item.TargetPort;PID='';Owner='';Note='No listener'}
    }
    $rows = @()
    foreach ($c in $connections) {
        $cmd = Get-ProcessCommandLine ([int]$c.OwningProcess)
        $normalized = $cmd -replace '\\','/'
        $isExpected = $false
        if ($item.Kind -eq 'Kubernetes port-forward') { $isExpected = ($normalized -match 'kubectl(\.exe)?' -and $normalized -like "*$($item.Match)*" -and $normalized -like "*$($item.LocalPort):$($item.TargetPort)*") }
        elseif ($item.Kind -eq 'Local GUI') { $isExpected = ($normalized -like '*python*' -and $normalized -like "*$($item.Match)*") }
        else { $isExpected = ($normalized -match 'java(\.exe)?' -and $normalized -like "*$($item.Match)*") }
        $owner = if ($cmd) { ($cmd -replace '\s+',' ').Trim() } else { 'PID '+$c.OwningProcess }
        $rows += [pscustomobject]@{Status=if($isExpected){'RUNNING'}else{'NOT RUNNING'};Kind=$item.Kind;Service=$item.Service;LocalPort=$item.LocalPort;TargetPort=$item.TargetPort;PID=$c.OwningProcess;Owner=$owner;Note=if($isExpected){'Expected demo listener'}else{'Listener is not a confirmed demo forward/process'}}
    }
    return $rows
}

$results = foreach ($item in $expected) { Test-ExpectedListener $item }
Write-Host 'Demo port-forward and local-process status (read-only)' -ForegroundColor Cyan
$results | Format-Table Status,Kind,Service,LocalPort,TargetPort,PID,Note -AutoSize
$missing = @($results | Where-Object Status -ne 'RUNNING')
Write-Host ''
if ($missing.Count -eq 0) { Write-Host 'SUMMARY: PASS - all expected demo endpoints are confirmed.' -ForegroundColor Green; exit 0 }
Write-Host ("SUMMARY: FAIL - {0} expected endpoint(s) are missing or owned by an unrelated process." -f $missing.Count) -ForegroundColor Yellow
exit 1
