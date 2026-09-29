param([switch]$Live)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dashboard = Get-Content (Join-Path $root 'infrastructure/monitoring/prometheus/grafana-dashboard.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Assert([bool]$ok, [string]$message) {
    if (-not $ok) { throw $message }
}

function Test-Panel($panel) {
    $expectedTitle = 'E6 ' + [char]0x2014 + ' Product pod replacement and recovery'
    Assert ($null -ne $panel -and $panel.title -eq $expectedTitle) "E6 panel missing or retitled (got '$($panel.title)')"
    Assert (-not $panel.timeFrom -and -not $panel.timeShift) 'E6 must follow the Grafana time picker'
    Assert ($panel.fieldConfig.defaults.unit -eq 'none' -and $panel.fieldConfig.defaults.decimals -eq 0) 'E6 state values must render as whole numbers'
    Assert ($panel.fieldConfig.defaults.min -eq 0 -and $panel.fieldConfig.defaults.max -eq 1) 'E6 must use a 0/1 axis'
    Assert ($panel.fieldConfig.defaults.custom.axisLabel -eq 'State (0 = No, 1 = Yes)') 'E6 axis label is unclear'
    Assert ($panel.fieldConfig.defaults.custom.lineInterpolation -eq 'stepAfter') 'E6 state changes must be shown as steps'
    $expected = @(
        @{expr='adaptive_recovery_e6_product_ready'; legend='Product Ready (0/1)'; color='green'},
        @{expr='adaptive_recovery_e6_replacement_verified'; legend='Replacement UID verified (0/1)'; color='blue'},
        @{expr='adaptive_recovery_e6_pod_kill_active'; legend='PodChaos active (0/1)'; color='orange'}
    )
    Assert (@($panel.targets).Count -eq 3) 'E6 must have exactly three real metric series'
    foreach ($item in $expected) {
        $target = @($panel.targets | Where-Object { $_.expr -eq $item.expr -and $_.legendFormat -eq $item.legend })
        Assert ($target.Count -eq 1) "E6 query or legend mismatch: $($item.expr)"
        $override = @($panel.fieldConfig.overrides | Where-Object { $_.matcher.options -eq $item.legend })
        Assert ($override.Count -eq 1) "E6 color override missing: $($item.legend)"
        $color = @($override[0].properties | Where-Object id -eq 'color')[0].value.fixedColor
        Assert ($color -eq $item.color) "E6 color mismatch: $($item.legend)"
    }
}

function Test-EventsPanel($panel) {
    $expectedTitle='E6 ' + [char]0x2014 + ' Observed events'
    Assert ($null -ne $panel -and $panel.title -eq $expectedTitle) 'E6 observed-events panel missing'
    Assert (-not $panel.timeFrom -and -not $panel.timeShift) 'E6 event panel must follow the time picker'
    Assert ($panel.description.Contains('not current Product state') -and $panel.description.Contains('next run')) 'E6 event panel must identify retained recorded events'
    Assert ($panel.fieldConfig.defaults.unit -eq 'none' -and $panel.fieldConfig.defaults.min -eq 0 -and $panel.fieldConfig.defaults.max -eq 1) 'E6 event panel must use a 0/1 axis'
    $expected = @(
        @{expr='adaptive_recovery_e6_interruption_observed'; color='red'},
        @{expr='adaptive_recovery_e6_healthy_replacement_verified'; color='green'}
    )
    Assert (@($panel.targets).Count -eq 2) 'E6 event panel must contain exactly two E6-only metrics'
    foreach($item in $expected) {
        $target=@($panel.targets|Where-Object {$_.expr -eq $item.expr})
        Assert ($target.Count -eq 1 -and $target[0].legendFormat.Contains('recorded event')) "Missing recorded-event legend: $($item.expr)"
        $override=@($panel.fieldConfig.overrides|Where-Object {$_.matcher.options -eq $target[0].legendFormat})
        Assert ($override.Count -eq 1) "Missing event color: $($item.expr)"
        $color=@($override[0].properties|Where-Object id -eq 'color')[0].value.fixedColor
        Assert ($color -eq $item.color) "Wrong E6 event color: $($item.expr)"
    }
}

$sourcePanel = @($dashboard.panels | Where-Object { $_.id -eq 106 })[0]
Test-Panel $sourcePanel
Test-EventsPanel (@($dashboard.panels | Where-Object { $_.id -eq 107 })[0])
if ($Live) {
    $uri = 'http://127.0.0.1:13000/api/dashboards/uid/' + $dashboard.uid
    # Windows PowerShell 5.1 can decode Grafana's UTF-8 JSON as ANSI when
    # the response omits a charset. Decode bytes explicitly for the title.
    $web = Invoke-WebRequest $uri -UseBasicParsing -TimeoutSec 8
    $response = [System.Text.Encoding]::UTF8.GetString($web.RawContentStream.ToArray()) | ConvertFrom-Json
    $livePanel = @($response.dashboard.panels | Where-Object { $_.id -eq 106 })[0]
    Test-Panel $livePanel
    Test-EventsPanel (@($response.dashboard.panels | Where-Object { $_.id -eq 107 })[0])
    'E6_LIVE_DASHBOARD_TEST=PASS'
} else {
    'E6_DASHBOARD_TEST=PASS'
}
