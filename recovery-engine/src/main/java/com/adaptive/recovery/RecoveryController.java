package com.adaptive.recovery;

import java.time.Instant;
import java.util.Collection;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api/recovery")
public class RecoveryController {
    private final RecoveryEngineService engine; private final E4RecoveryService e4; private final E4MetricsStore e4Store;
    private final E5RecoveryService e5; private final E5MetricsStore e5Store;
    private final Map<String,Double> e2=new ConcurrentHashMap<>(), e1=new ConcurrentHashMap<>(), e4Metrics=new ConcurrentHashMap<>(), e5Metrics=new ConcurrentHashMap<>(), e6Metrics=new ConcurrentHashMap<>();
    private final AtomicLong e2VerifiedActions=new AtomicLong();
    private final AtomicReference<String> e6CurrentRun=new AtomicReference<>();
    @org.springframework.beans.factory.annotation.Autowired RecoveryController(RecoveryEngineService s,E4RecoveryService e4,E4MetricsStore e4Store,E5RecoveryService e5,E5MetricsStore e5Store){engine=s;this.e4=e4;this.e4Store=e4Store;this.e5=e5;this.e5Store=e5Store;}
    RecoveryController(RecoveryEngineService s){engine=s;this.e4=null;this.e4Store=new E4MetricsStore();this.e5=null;this.e5Store=new E5MetricsStore();}
    @PostMapping("/evaluate/{service}") RecoveryRecord evaluate(@PathVariable String service,@RequestParam(defaultValue="false") boolean execute,@RequestParam(required=false) String profile){RecoveryRecord r=engine.evaluate(service,execute,profile);if("e2-memory".equals(profile)&&service.contains("inventory")){e2.put("memory_ratio",r.signals().memory());e2.put("memory_bytes",r.signals().memory()*536870912d);e2.put("action_verified",execute&&r.actionVerified()?1d:0d);e2.put("decision",r.decision()==RecoveryDecision.INCREASE_MEMORY?1d:0d);if(execute&&r.actionVerified())e2VerifiedActions.incrementAndGet();}return r;}
    @PostMapping("/e4/evaluate") RecoveryRecord evaluateE4(@RequestParam(defaultValue="false") boolean execute){if(e4==null)throw new ResponseStatusException(HttpStatus.NOT_IMPLEMENTED,"E4 actuator unavailable");return e4.evaluate(execute);}
    @PostMapping("/e5/start") void startE5(@RequestHeader(value="X-E5-Runner",required=false) String runner){if(!"local-fixed-e5".equals(runner))throw new ResponseStatusException(HttpStatus.FORBIDDEN,"fixed E5 runner header required");if(e5==null)throw new ResponseStatusException(HttpStatus.NOT_IMPLEMENTED,"E5 policy unavailable");e5.beginRun();e5Metrics.put("http_500",0d);e5Metrics.put("http_500_consecutive",0d);e5Metrics.put("decision",0d);e5Metrics.put("restart_verified",0d);e5Metrics.put("simulated_action",0d);}
    @PostMapping("/e5/evaluate") RecoveryRecord evaluateE5(@RequestParam(defaultValue="false") boolean execute){if(e5==null)throw new ResponseStatusException(HttpStatus.NOT_IMPLEMENTED,"E5 policy unavailable");RecoveryRecord r=e5.evaluate(execute);e5Metrics.put("decision",r.decision()==RecoveryDecision.SIMULATED_RESTART?1d:r.decision()==RecoveryDecision.OBSERVE?0.5d:0d);e5Metrics.put("http_500_consecutive",(double)r.signals().persistenceSamples());e5Metrics.put("restart_verified",r.decision()==RecoveryDecision.SIMULATED_RESTART&&execute&&r.actionVerified()?1d:0d);if(r.decision()==RecoveryDecision.SIMULATED_RESTART&&execute&&r.actionVerified())e5Metrics.put("simulated_action",1d);return r;}
    @PostMapping("/e1/sample") void e1Sample(@RequestBody Map<String,Object> s){
        Object c=s.get("cpuCores");
        if(!(c instanceof Number)||!Double.isFinite(((Number)c).doubleValue())||((Number)c).doubleValue()<0)
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"cpuCores must be a valid non-negative number");
        Object source=s.get("sourceTimestamp");
        if(source!=null){
            if(!(source instanceof String))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"sourceTimestamp must be ISO-8601");
            try{e1.put("cpu_source_timestamp_seconds",Instant.parse((String)source).toEpochMilli()/1000d);}
            catch(java.time.format.DateTimeParseException ex){throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"sourceTimestamp must be ISO-8601");}
        } else e1.remove("cpu_source_timestamp_seconds");
        e1.put("cpu_cores",((Number)c).doubleValue());
    }
    @PostMapping("/e1/unavailable") void e1Unavailable(){e1.remove("cpu_cores");e1.remove("cpu_source_timestamp_seconds");}
    @PostMapping("/e2/sample") void e2Sample(@RequestBody Map<String,Object> s){Object b=s.get("memoryBytes"),r=s.get("memoryRatio");if(!(b instanceof Number)||!(r instanceof Number))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"memoryBytes and memoryRatio must be numeric");double bd=((Number)b).doubleValue(),rd=((Number)r).doubleValue();if(!Double.isFinite(bd)||!Double.isFinite(rd)||bd<=0||rd<=0||rd>1)throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"invalid E2 sample");e2.put("memory_bytes",bd);e2.put("memory_ratio",rd);}
    @PostMapping("/e4/sample") void e4Sample(@RequestBody Map<String,Object> s){Object lm=s.get("latencyMs"),mv=s.containsKey("mitigationVerified")?s.get("mitigationVerified"):s.get("restartVerified");if(!(lm instanceof Number)||!(mv instanceof Number))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"latencyMs and mitigationVerified must be numeric");double l=((Number)lm).doubleValue(),v=((Number)mv).doubleValue();if(!Double.isFinite(l)||!Double.isFinite(v)||l<0||v<0||v>1)throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"invalid E4 sample");e4Store.publish(new E4MetricsStore.Sample(l,0,v));e4Metrics.put("latency_ms",l);e4Metrics.put("mitigation_verified",v);}
    @PostMapping("/e5/sample") void e5Sample(@RequestBody Map<String,Object> s){Object st=s.get("httpStatus"),at=s.get("timestamp");if(!(st instanceof Number)||!(at instanceof String))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"httpStatus and timestamp are required");try{if(!e5Store.publish(Instant.parse((String)at),((Number)st).intValue()))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"sample timestamp is stale or invalid");e5Metrics.put("http_500",((Number)st).intValue()==500?1d:0d);Object sim=s.get("simulatedRestart");if(sim instanceof Number&&((Number)sim).doubleValue()==1d)e5Metrics.put("simulated_restart",1d);}catch(java.time.format.DateTimeParseException ex){throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"timestamp must be ISO-8601");}}
    @PostMapping("/e6/sample") void e6Sample(@RequestBody Map<String,Object> s){Object pr=s.get("productReady"),rv=s.get("replacementVerified"),ca=s.get("podKillActive");if(!(pr instanceof Number)||!(rv instanceof Number)||!(ca instanceof Number))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"productReady, replacementVerified and podKillActive must be numeric");double p=((Number)pr).doubleValue(),r=((Number)rv).doubleValue(),c=((Number)ca).doubleValue();if(!Double.isFinite(p)||!Double.isFinite(r)||!Double.isFinite(c)||p<0||p>1||r<0||r>1||c<0||c>1)throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"invalid E6 sample");e6Metrics.put("product_ready",p);e6Metrics.put("replacement_verified",r);e6Metrics.put("pod_kill_active",c);}
    @PostMapping("/e6/events/start") synchronized void startE6Events(@RequestHeader(value="X-E6-Runner",required=false) String runner,@RequestBody Map<String,Object> body){
        if(!"local-fixed-e6".equals(runner))throw new ResponseStatusException(HttpStatus.FORBIDDEN,"fixed E6 runner header required");
        Object runId=body.get("runId");
        if(!(runId instanceof String)||!((String)runId).matches("E6-\\d{8}-\\d{6}\\+0530"))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"valid E6 runId required");
        e6Metrics.put("interruption_observed",0d);
        e6Metrics.put("healthy_replacement_verified",0d);
        e6CurrentRun.set((String)runId);
    }
    @PostMapping("/e6/events/observe") synchronized void observeE6Event(@RequestHeader(value="X-E6-Runner",required=false) String runner,@RequestBody Map<String,Object> body){
        if(!"local-fixed-e6".equals(runner))throw new ResponseStatusException(HttpStatus.FORBIDDEN,"fixed E6 runner header required");
        if(e6CurrentRun.get()==null||!e6CurrentRun.get().equals(body.get("runId")))throw new ResponseStatusException(HttpStatus.CONFLICT,"E6 event belongs to a different run");
        Object ready=body.get("ready"),health=body.get("health");
        if(!(ready instanceof Boolean)||!(health instanceof Boolean))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"boolean readiness and health evidence required");
        if("product-interruption-observed".equals(body.get("event"))){
            if(Boolean.TRUE.equals(ready)&&Boolean.TRUE.equals(health))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"interruption requires unready or unhealthy observation");
            e6Metrics.put("interruption_observed",1d);
        }else if("healthy-replacement-verified".equals(body.get("event"))){
            Object original=body.get("baselineUid"),replacement=body.get("replacementUid");
            if(!Boolean.TRUE.equals(ready)||!Boolean.TRUE.equals(health)||!(original instanceof String)||!(replacement instanceof String)||((String)original).isBlank()||((String)replacement).isBlank()||original.equals(replacement))throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"different healthy Ready replacement UID required");
            e6Metrics.put("healthy_replacement_verified",1d);
        }else throw new ResponseStatusException(HttpStatus.BAD_REQUEST,"unknown E6 event");
    }
    @GetMapping("/records") Collection<RecoveryRecord> records(){return engine.records();}
    @GetMapping(value="/e2/metrics",produces="text/plain") String e2Metrics(){return "# HELP adaptive_recovery_e1_cpu_cores Inventory container CPU cores from Metrics API\n# TYPE adaptive_recovery_e1_cpu_cores gauge\nadaptive_recovery_e1_cpu_cores "+e1.getOrDefault("cpu_cores",Double.NaN)+"\n# TYPE adaptive_recovery_e1_cpu_source_timestamp_seconds gauge\nadaptive_recovery_e1_cpu_source_timestamp_seconds "+e1.getOrDefault("cpu_source_timestamp_seconds",Double.NaN)+"\n# HELP adaptive_recovery_e2_memory_ratio Inventory container memory usage / limit\n# TYPE adaptive_recovery_e2_memory_ratio gauge\nadaptive_recovery_e2_memory_ratio "+e2.getOrDefault("memory_ratio",Double.NaN)+"\n# TYPE adaptive_recovery_e2_memory_bytes gauge\nadaptive_recovery_e2_memory_bytes "+e2.getOrDefault("memory_bytes",Double.NaN)+"\n# TYPE adaptive_recovery_e2_action_verified gauge\nadaptive_recovery_e2_action_verified "+e2.getOrDefault("action_verified",0d)+"\n# TYPE adaptive_recovery_e2_verified_actions_total counter\nadaptive_recovery_e2_verified_actions_total "+e2VerifiedActions.get()+"\n# TYPE adaptive_recovery_e2_decision gauge\nadaptive_recovery_e2_decision "+e2.getOrDefault("decision",0d)+"\n# TYPE adaptive_recovery_e4_order_inventory_latency_ms gauge\nadaptive_recovery_e4_order_inventory_latency_ms "+e4Metrics.getOrDefault("latency_ms",Double.NaN)+"\n# TYPE adaptive_recovery_e4_mitigation_verified gauge\nadaptive_recovery_e4_mitigation_verified "+e4Metrics.getOrDefault("mitigation_verified",0d)+"\n# TYPE adaptive_recovery_e5_http_500 gauge\nadaptive_recovery_e5_http_500 "+e5Metrics.getOrDefault("http_500",Double.NaN)+"\n# TYPE adaptive_recovery_e5_http_500_consecutive gauge\nadaptive_recovery_e5_http_500_consecutive "+e5Metrics.getOrDefault("http_500_consecutive",0d)+"\n# TYPE adaptive_recovery_e5_restart_verified gauge\nadaptive_recovery_e5_restart_verified "+e5Metrics.getOrDefault("restart_verified",0d)+"\n# TYPE adaptive_recovery_e5_simulated_action gauge\nadaptive_recovery_e5_simulated_action "+e5Metrics.getOrDefault("simulated_action",0d)+"\n# HELP adaptive_recovery_e6_interruption_observed Product interruption recorded by the current E6 runner, not live readiness\n# TYPE adaptive_recovery_e6_interruption_observed gauge\nadaptive_recovery_e6_interruption_observed "+e6Metrics.getOrDefault("interruption_observed",Double.NaN)+"\n# HELP adaptive_recovery_e6_healthy_replacement_verified Different Ready and healthy Product replacement recorded by the current E6 runner\n# TYPE adaptive_recovery_e6_healthy_replacement_verified gauge\nadaptive_recovery_e6_healthy_replacement_verified "+e6Metrics.getOrDefault("healthy_replacement_verified",Double.NaN)+"\n# TYPE adaptive_recovery_e6_product_ready gauge\nadaptive_recovery_e6_product_ready "+e6Metrics.getOrDefault("product_ready",Double.NaN)+"\n# TYPE adaptive_recovery_e6_replacement_verified gauge\nadaptive_recovery_e6_replacement_verified "+e6Metrics.getOrDefault("replacement_verified",Double.NaN)+"\n# TYPE adaptive_recovery_e6_pod_kill_active gauge\nadaptive_recovery_e6_pod_kill_active "+e6Metrics.getOrDefault("pod_kill_active",Double.NaN)+"\n";}
}
