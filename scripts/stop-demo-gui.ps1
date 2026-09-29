$root=Split-Path $PSScriptRoot -Parent
foreach($f in @('gui\.gui-pid','gui\.portforward-pids','gui\.engine-pid')){ $p=Join-Path $root $f; if(Test-Path $p){Get-Content $p|ForEach-Object{Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue};Remove-Item $p -Force}}
$patterns=@("*gui\server.py*","*recovery-engine-0.1.0-SNAPSHOT.jar*","*run-e4-order-http500.ps1*","*run-e5-order-http500.ps1*","*port-forward*svc/adaptive-product-service*","*port-forward*svc/adaptive-inventory-service*","*port-forward*svc/adaptive-order-service*","*port-forward*svc/adaptive-recovery-prometheus*","*port-forward*svc/adaptive-recovery-grafana*")
Get-CimInstance Win32_Process | ForEach-Object {$cmd=$_.CommandLine;if($cmd -and ($patterns | Where-Object {$cmd -like $_})){Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}}
$ports=@(18080,8090,18081,18082,18083,19090,13000)
Start-Sleep -Seconds 1
foreach($port in $ports){$listeners=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue;if($listeners){Write-Host "FAIL port $port still has listener PID(s): $($listeners.OwningProcess -join ',')"}else{Write-Host "PASS port $port has no demo listener"}}
