package com.adaptive.recovery;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;


@Component
public class KubernetesReader {
  public static final String BASE_CPU_REQUEST="100m", BASE_CPU_LIMIT="500m", BASE_MEMORY_REQUEST="256Mi", BASE_MEMORY_LIMIT="512Mi";
  public static final String TARGET_CPU_REQUEST="200m", TARGET_CPU_LIMIT="600m", TARGET_MEMORY_REQUEST="384Mi", TARGET_MEMORY_LIMIT="768Mi";

  private final String ns, kubectl;
  private volatile CommandResult lastRestartResult = new CommandResult(-1,"","not run");
  private volatile String lastRestartDiagnostic = "not run";
  private volatile String lastCpuDiagnostic = "not read";
  private volatile String lastMemoryDiagnostic = "not read";
  private volatile String lastHealthDiagnostic = "not read";
  private final String delayUrl;
  private volatile String lastMitigationOutcome = "not run";

  KubernetesReader(@Value("${recovery.namespace}") String ns,
                   @Value("${recovery.kubectl-bin:kubectl}") String kubectl,
                   @Value("${recovery.e4-delay-url:http://127.0.0.1:18083/api/internal/e3-delay}") String delayUrl) {
    this.ns=ns;
    this.kubectl=resolveKubectl(kubectl);
    this.delayUrl=delayUrl;
  }

  static String resolveKubectl(String configured) {
    return configured == null || configured.isBlank() ? "kubectl" : configured.trim();
  }

  public boolean healthy(String service) {
    CommandResult result=run(kubectl,"get","deployment",service,"-n",ns,"-o","json");
    if(result.exitCode()!=0){lastHealthDiagnostic=commandFailure("Kubernetes Deployment readiness",result);return false;}
    boolean healthy=deploymentHealthy(result.stdout());
    lastHealthDiagnostic=healthy?"Deployment has desired replicas Ready and Available":"Deployment JSON does not show all desired replicas Ready and Available";
    return healthy;
  }

  static boolean deploymentHealthy(String json) {
    try {
      java.util.regex.Matcher desiredMatcher=java.util.regex.Pattern.compile("\\\"spec\\\"\\s*:\\s*\\{.*?\\\"replicas\\\"\\s*:\\s*([0-9]+)",java.util.regex.Pattern.DOTALL).matcher(json);
      java.util.regex.Matcher readyMatcher=java.util.regex.Pattern.compile("\\\"readyReplicas\\\"\\s*:\\s*([0-9]+)").matcher(json);
      java.util.regex.Matcher availableMatcher=java.util.regex.Pattern.compile("\\\"availableReplicas\\\"\\s*:\\s*([0-9]+)").matcher(json);
      int desired=desiredMatcher.find()?Integer.parseInt(desiredMatcher.group(1)):1;
      return desired>0 && readyMatcher.find() && availableMatcher.find() && Integer.parseInt(readyMatcher.group(1))>=desired && Integer.parseInt(availableMatcher.group(1))>=desired;
    } catch(Exception ignored) { return false; }
  }

  public double cpuCores(String service) {
    CommandResult result=run(kubectl,"get","--raw","/apis/metrics.k8s.io/v1beta1/namespaces/"+ns+"/pods");
    if(result.exitCode()!=0){lastCpuDiagnostic=commandFailure("Kubernetes Metrics API container CPU",result);return Double.NaN;}
    double value=cpuCoresFromMetrics(result.stdout(),service);
    lastCpuDiagnostic=Double.isFinite(value)?"read from Metrics API container usage.cpu":"no matching service pod/container usage.cpu in Metrics API response";
    return value;
  }

  static double cpuCoresFromMetrics(String json,String service) {
    try {
      String escaped=java.util.regex.Pattern.quote(service);
      java.util.regex.Matcher m=java.util.regex.Pattern.compile("\\\"name\\\"\\s*:\\s*\\\""+escaped+"-[^\\\"]+\\\"(?:(?!\\\"metadata\\\"\\s*:\\s*\\{).)*?\\\"name\\\"\\s*:\\s*\\\""+escaped+"\\\"(?:(?!\\\"name\\\"\\s*:\\s*\\\").)*?\\\"cpu\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"",java.util.regex.Pattern.DOTALL).matcher(json);
      if(m.find())return cpuQuantityToCores(m.group(1));
    } catch(Exception ignored) { }
    return Double.NaN;
  }

  static double cpuQuantityToCores(String value) {
    try {
      if(value==null||value.isBlank())return Double.NaN;
      if(value.endsWith("n"))return Double.parseDouble(value.substring(0,value.length()-1))/1_000_000_000d;
      if(value.endsWith("u"))return Double.parseDouble(value.substring(0,value.length()-1))/1_000_000d;
      if(value.endsWith("m"))return Double.parseDouble(value.substring(0,value.length()-1))/1_000d;
      return Double.parseDouble(value);
    } catch(Exception ignored) { return Double.NaN; }
  }

  public static double nanocoresToCores(String value){return cpuQuantityToCores(value);}

  public double memoryUsageRatio(String service) {
    CommandResult metrics=run(kubectl,"get","--raw","/apis/metrics.k8s.io/v1beta1/namespaces/"+ns+"/pods");
    if(metrics.exitCode()!=0){lastMemoryDiagnostic=commandFailure("Kubernetes Metrics API container memory",metrics);return Double.NaN;}
    CommandResult deployment=run(kubectl,"get","deployment",service,"-n",ns,"-o","json");
    if(deployment.exitCode()!=0){lastMemoryDiagnostic=commandFailure("Kubernetes Deployment memory limit",deployment);return Double.NaN;}
    double ratio=memoryUsageRatioFromMetrics(metrics.stdout(),deployment.stdout(),service);
    lastMemoryDiagnostic=Double.isFinite(ratio)?"Metrics API container usage.memory divided by Deployment container memory limit":"matching usage.memory or Deployment container memory limit unavailable/invalid";
    return ratio;
  }

  static double memoryUsageRatioFromMetrics(String metricsJson,String deploymentJson,String service) {
    try {
      String escaped=java.util.regex.Pattern.quote(service);
      java.util.regex.Matcher usageMatcher=java.util.regex.Pattern.compile("\\\"name\\\"\\s*:\\s*\\\""+escaped+"-[^\\\"]+\\\"(?:(?!\\\"metadata\\\"\\s*:\\s*\\{).)*?\\\"name\\\"\\s*:\\s*\\\""+escaped+"\\\"(?:(?!\\\"name\\\"\\s*:\\s*\\\").)*?\\\"memory\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"",java.util.regex.Pattern.DOTALL).matcher(metricsJson);
      java.util.regex.Matcher limitMatcher=java.util.regex.Pattern.compile("\\\"name\\\"\\s*:\\s*\\\""+escaped+"\\\".*?\\\"limits\\\"\\s*:\\s*\\{.*?\\\"memory\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"",java.util.regex.Pattern.DOTALL).matcher(deploymentJson);
      if(!usageMatcher.find()||!limitMatcher.find())return Double.NaN;
      double used=memoryQuantityBytes(usageMatcher.group(1));
      double limit=memoryQuantityBytes(limitMatcher.group(1));
      return Double.isFinite(used)&&Double.isFinite(limit)&&used>=0&&limit>0?used/limit:Double.NaN;
    } catch(Exception ignored) { return Double.NaN; }
  }

  public static double memoryQuantityBytes(String value){
    try{if(value==null||value.isBlank())return Double.NaN;String v=value.trim();double m=1;for(String[] u:new String[][]{{"Ki","1024"},{"Mi","1048576"},{"Gi","1073741824"},{"Ti","1099511627776"},{"KiB","1024"},{"MiB","1048576"},{"GiB","1073741824"},{"k","1000"},{"MB","1000000"},{"GB","1000000000"},{"M","1000000"},{"G","1000000000"}})if(v.endsWith(u[0])){m=Double.parseDouble(u[1]);v=v.substring(0,v.length()-u[0].length());break;}return Double.parseDouble(v)*m;}catch(Exception e){return Double.NaN;}
  }

  public String signalDiagnostics(){return "cpu="+lastCpuDiagnostic+"; memory="+lastMemoryDiagnostic+"; readiness="+lastHealthDiagnostic;}

  private String commandFailure(String label,CommandResult result){return label+" command failed using '"+kubectl+"' (exit "+result.exitCode()+"): "+result.stderr().trim();}
  public boolean increaseCpu(String s){return run(buildCpuCommand(kubectl,ns,s)).exitCode()==0;}
  public boolean increaseMemory(String s){return setResources(s,"memory="+TARGET_MEMORY_REQUEST,"memory="+TARGET_MEMORY_LIMIT);}
  public boolean restore(String s,String cpuRequest,String cpuLimit,String memoryRequest,String memoryLimit){return patchResources(s,cpuRequest,cpuLimit,memoryRequest,memoryLimit);}
  /** E4-only allowlist: never accepts an arbitrary deployment name. */
  public boolean restartOrderPod(){
    String baseline = readyOrderPodUid();
    lastRestartResult = run(buildOrderRestartCommand(kubectl,ns));
    if(lastRestartResult.exitCode()!=0){lastRestartDiagnostic="restart command failed; "+lastRestartOutcome();return false;}
    CommandResult rollout=run(kubectl,"rollout","status","deployment/adaptive-order-service","-n",ns,"--timeout=120s");
    if(rollout.exitCode()!=0){lastRestartDiagnostic="rollout status failed; exit="+rollout.exitCode()+"; stdout="+rollout.stdout()+"; stderr="+rollout.stderr();return false;}
    for(int i=0;i<60;i++){String uid=readyOrderPodUid();if(uid!=null&&!uid.isBlank()&&!uid.equals(baseline)){lastRestartDiagnostic="replacement Ready pod observed; baselineUid="+baseline+"; afterUid="+uid+"; rolloutExit="+rollout.exitCode();return true;}try{Thread.sleep(1000);}catch(InterruptedException e){Thread.currentThread().interrupt();break;}}
    lastRestartDiagnostic="replacement Ready pod UID not observed before timeout; baselineUid="+baseline+"; currentUid="+readyOrderPodUid()+"; rolloutExit="+rollout.exitCode();return false;
  }
  public String lastRestartOutcome(){return "exit="+lastRestartResult.exitCode()+"; stdout="+lastRestartResult.stdout()+"; stderr="+lastRestartResult.stderr()+"; diagnostic="+lastRestartDiagnostic;}
  static boolean confirmsDelayOff(int status,String body){if(status!=200||body==null)return false;java.util.regex.Matcher enabled=java.util.regex.Pattern.compile("\\\"enabled\\\"\\s*:\\s*(true|false)").matcher(body);java.util.regex.Matcher delay=java.util.regex.Pattern.compile("\\\"delayMs\\\"\\s*:\\s*(-?[0-9]+)").matcher(body);return enabled.find()&&"false".equals(enabled.group(1))&&delay.find()&&"0".equals(delay.group(1));}
  public boolean disableOrderDelay(){try{var client=java.net.http.HttpClient.newHttpClient();var req=java.net.http.HttpRequest.newBuilder(java.net.URI.create(delayUrl)).header("Content-Type","application/json").POST(java.net.http.HttpRequest.BodyPublishers.ofString("{\"enabled\":false,\"delayMs\":0}")).build();var res=client.send(req,java.net.http.HttpResponse.BodyHandlers.ofString());boolean ok=confirmsDelayOff(res.statusCode(),res.body());lastMitigationOutcome="http="+res.statusCode()+"; body="+res.body()+"; confirmedDelayOff="+ok;return ok;}catch(Exception e){lastMitigationOutcome="error="+e;return false;}}
  public String lastMitigationOutcome(){return lastMitigationOutcome;}
  private static final java.util.regex.Pattern READY_POD_UID = java.util.regex.Pattern.compile("\\\"metadata\\\"\\s*:\\s*\\{(?:(?!\\\"metadata\\\").)*?\\\"uid\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"(?:(?!\\\"metadata\\\").)*?\\\"ready\\\"\\s*:\\s*true",java.util.regex.Pattern.DOTALL);
  static boolean hasDifferentReadyPod(String baselineUid,String json){if(json==null||baselineUid==null)return false;return READY_POD_UID.matcher(json).results().anyMatch(m->!baselineUid.equals(m.group(1)));}
  private String readyOrderPodUid(){try{String json=run(kubectl,"get","pods","-n",ns,"-l","app.kubernetes.io/name=adaptive-order-service","-o","json").stdout();java.util.regex.Matcher m=READY_POD_UID.matcher(json);return m.find()?m.group(1):null;}catch(Exception e){return null;}}
  static String[] buildOrderRestartCommand(String kubectl,String namespace){return new String[]{kubectl,"rollout","restart","deployment/adaptive-order-service","-n",namespace};}
  static String[] buildCpuCommand(String kubectl,String namespace,String service){return new String[]{kubectl,"set","resources","deployment",service,"-n",namespace,"-c",service,"--requests=cpu="+TARGET_CPU_REQUEST,"--limits=cpu="+TARGET_CPU_LIMIT};}
  private boolean setResources(String s,String request,String limit){return run(kubectl,"set","resources","deployment",s,"-n",ns,"-c",s,"--requests="+request,"--limits="+limit).exitCode()==0;}
  private boolean patchResources(String s,String cpuRequest,String cpuLimit,String memoryRequest,String memoryLimit){StringBuilder p=new StringBuilder("{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"").append(s).append("\",\"resources\":{\"requests\":{"); if(cpuRequest!=null)p.append("\"cpu\":\"").append(cpuRequest).append("\""); if(memoryRequest!=null){if(cpuRequest!=null)p.append(',');p.append("\"memory\":\"").append(memoryRequest).append("\"");} p.append("},\"limits\":{"); if(cpuLimit!=null)p.append("\"cpu\":\"").append(cpuLimit).append("\""); if(memoryLimit!=null){if(cpuLimit!=null)p.append(',');p.append("\"memory\":\"").append(memoryLimit).append("\"");} p.append("}}]}}}}"); return run(kubectl,"patch","deployment",s,"-n",ns,"--type=merge","-p",p.toString()).exitCode()==0;}
  private CommandResult run(String... c){try{var p=new ProcessBuilder(c).redirectErrorStream(false).start(); String out=new String(p.getInputStream().readAllBytes()); String err=new String(p.getErrorStream().readAllBytes()); return new CommandResult(p.waitFor(),out,err);}catch(Exception e){return new CommandResult(-1,"",e.toString());}}
  record CommandResult(int exitCode,String stdout,String stderr){}
}
