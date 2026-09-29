package com.adaptive.recovery;
import org.springframework.beans.factory.annotation.Value; import org.springframework.stereotype.Component; import org.springframework.web.client.RestClient;
@Component public class PrometheusReader { private final RestClient client; public PrometheusReader(@Value("${recovery.prometheus-url}") String url){client=RestClient.builder().baseUrl(url).build();}
  public Signals read(String service,int window,boolean healthy){
    double cpu=query("process_cpu_usage",service);
    double used=queryExpression("sum(jvm_memory_used_bytes{service=\""+service+"\"})"), max=queryExpression("sum(jvm_memory_max_bytes{service=\""+service+"\"})");
    double memory=max>0?used/max:Double.NaN;
    double errors=query("sum(rate(http_server_requests_seconds_count{service=\""+service+"\",status=~\"5..\"}[5m]))",null);
    double latency=query("histogram_quantile(0.95,sum(rate(http_server_requests_seconds_bucket{service=\""+service+"\"}[5m])) by (le))",null);
    int checks=service.equals("adaptive-order-service")?(query("adaptive_order_dependency_probe_total",service)>0?window:0):-1;
    return new Signals(cpu,memory,healthy?1:0,errors,latency,healthy,checks,window,healthy);
  }
  /** Route-scoped 5xx rate used only by the E4 profile. Missing data is NaN, not zero. */
  public double routeHttp500Rate(String service,String uri){
    return queryExpression("sum(rate(http_server_requests_seconds_count{service=\""+service+"\",uri=\""+uri+"\",status=\"500\"}[1m]))");
  }
  private double query(String metric,String service){ try { String selector=service==null?metric:metric+"{service=\""+service+"\"}"; String encoded=java.net.URLEncoder.encode(selector,java.nio.charset.StandardCharsets.UTF_8); var body=client.get().uri(java.net.URI.create("/api/v1/query?query="+encoded)).retrieve().body(java.util.Map.class); var data=(java.util.Map<?,?>)body.get("data"); var result=(java.util.List<?>)data.get("result"); if(result.isEmpty()) return 0; var row=(java.util.Map<?,?>)result.get(0); var value=(java.util.List<?>)row.get("value"); return Double.parseDouble(value.get(1).toString()); } catch(Exception e){ return 0; } }
  private double queryExpression(String selector){ try { String encoded=java.net.URLEncoder.encode(selector,java.nio.charset.StandardCharsets.UTF_8); var body=client.get().uri(java.net.URI.create("/api/v1/query?query="+encoded)).retrieve().body(java.util.Map.class); var data=(java.util.Map<?,?>)body.get("data"); var result=(java.util.List<?>)data.get("result"); if(result.isEmpty()) return Double.NaN; var row=(java.util.Map<?,?>)result.get(0); var value=(java.util.List<?>)row.get("value"); return Double.parseDouble(value.get(1).toString()); } catch(Exception e){ return Double.NaN; } }
}
