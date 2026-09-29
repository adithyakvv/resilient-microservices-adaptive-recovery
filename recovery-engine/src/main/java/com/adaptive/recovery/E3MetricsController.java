package com.adaptive.recovery;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;
@RestController @RequestMapping("/api/recovery/e3")
public class E3MetricsController {
  private final Map<String,Double> values=new ConcurrentHashMap<>();
  @PostMapping("/sample") public void sample(@RequestBody Map<String,Object> b){Object l=b.get("latencyMs"),s=b.get("probeSuccesses"),f=b.get("probeFailures");if(!(l instanceof Number)||!(s instanceof Number)||!(f instanceof Number))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"numeric fields required");double ld=((Number)l).doubleValue(),sd=((Number)s).doubleValue(),fd=((Number)f).doubleValue();if(!Double.isFinite(ld)||!Double.isFinite(sd)||!Double.isFinite(fd)||ld<0||sd<0||fd<0)throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"invalid sample");values.put("latency_ms",ld);values.put("probe_successes",sd);values.put("probe_failures",fd);}
  @GetMapping(value="/metrics",produces="text/plain") public String metrics(){return "# HELP adaptive_order_inventory_latency_ms Order to Inventory latency milliseconds\n# TYPE adaptive_order_inventory_latency_ms gauge\nadaptive_order_inventory_latency_ms "+values.getOrDefault("latency_ms",Double.NaN)+"\n# HELP adaptive_order_dependency_probe_successes Order to Inventory probe successes\n# TYPE adaptive_order_dependency_probe_successes gauge\nadaptive_order_dependency_probe_successes "+values.getOrDefault("probe_successes",Double.NaN)+"\n# HELP adaptive_order_dependency_probe_failures Order to Inventory probe failures\n# TYPE adaptive_order_dependency_probe_failures gauge\nadaptive_order_dependency_probe_failures "+values.getOrDefault("probe_failures",Double.NaN)+"\n";}
}
