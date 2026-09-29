$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$html=Get-Content (Join-Path $root 'gui/index.html') -Raw

function Assert([bool]$ok,[string]$message){if(-not $ok){throw $message}}

$expectedLinks=@{
  'product-service'='/product.html'
  'inventory-service'='/inventory.html'
  'order-service'='/order.html'
  'grafana'='http://localhost:13000'
  'prom'='http://localhost:19090/graph'
  'engine'='http://localhost:8090/api/recovery/records'
}
foreach($id in $expectedLinks.Keys){
  $pattern='<a\b(?=[^>]*\bid="'+[regex]::Escape($id)+'")(?=[^>]*\bhref="'+[regex]::Escape($expectedLinks[$id])+'")'
  Assert ([regex]::IsMatch($html,$pattern)) "Navigation link $id must target $($expectedLinks[$id])"
}
foreach($label in @('Product Service','Inventory Service','Order Service','Grafana','Prometheus','Engine API')){
  Assert ($html.Contains('>'+ $label +'</a>')) "Missing navigation label $label"
}
foreach($removed in @('id="services"','async function cards(','async function add(','async function del(','Create demo record','Health: ${text(')){
  Assert (-not $html.Contains($removed)) "Embedded service CRUD UI remains: $removed"
}
foreach($id in @('metrics','decision','e1-panel','e2-panel','e3-panel','e4-panel','e5-panel','e6-panel')){
  Assert ($html.Contains('id="'+$id+'"')) "Main GUI section missing: $id"
}
foreach($page in @(@('product.html','product'),@('inventory.html','inventory'),@('order.html','order'))){
  $pageHtml=Get-Content (Join-Path $root ('gui\'+$page[0])) -Raw
  Assert ($pageHtml.Contains('data-service="'+$page[1]+'"')) "Service page does not select $($page[1])"
  Assert ($pageHtml.Contains('id="service-health"') -and $pageHtml.Contains('id="service-records"') -and $pageHtml.Contains('id="create-record"')) "Service page controls missing for $($page[1])"
}
foreach($run in @('runE1()','runE2()','runE3()','runE4()','runE5()','runE6()')){
  Assert ($html.Contains($run)) "Experiment control missing: $run"
}
'GUI_NAVIGATION_LAYOUT=PASS'
