$ErrorActionPreference='Stop'
$html=(Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:18080/' -TimeoutSec 5).Content
foreach($title in @('Experiment E1','Experiment E2','E3 — Network Degradation/Loss','Experiment E4','E5 — HTTP 500 Application Fault','E6 — Product Pod Kill')){if(-not $html.Contains($title)){throw "Served page missing $title"}}
foreach($link in @('Product Service','Inventory Service','Order Service','Grafana','Prometheus','Engine API')){if(-not $html.Contains('>'+ $link +'</a>')){throw "Served page missing navigation link $link"}}
foreach($href in @('/product.html','/inventory.html','/order.html')){if(-not $html.Contains($href)){throw "Served page missing service page target $href"}}
if($html.Contains('id="services"') -or $html.Contains('Create demo record') -or $html.Contains('async function cards(')){throw 'Served page still contains embedded service cards or CRUD controls'}
foreach($page in @(@('/product.html','data-service="product"'),@('/inventory.html','data-service="inventory"'),@('/order.html','data-service="order"'))){
  $response=(Invoke-WebRequest -UseBasicParsing ('http://127.0.0.1:18080'+$page[0]) -TimeoutSec 5).Content
  if(-not $response.Contains($page[1])){throw "Served service page $($page[0]) has the wrong service mapping"}
  foreach($required in @('id="service-health"','id="service-records"','id="create-record"','/service-page.js')){if(-not $response.Contains($required)){throw "Served service page $($page[0]) is missing $required"}}
}
'GUI_SERVED_PAGE_E1_E2_E3_E4_E5_E6_AND_NAVIGATION=PASS'
