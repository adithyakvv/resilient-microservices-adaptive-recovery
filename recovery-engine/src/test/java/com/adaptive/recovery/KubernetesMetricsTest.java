package com.adaptive.recovery;
import org.junit.jupiter.api.Test; import static org.junit.jupiter.api.Assertions.*;
class KubernetesMetricsTest {
  private static final String METRICS="""
      {"items":[{"metadata":{"name":"adaptive-inventory-service-596c4645b7-nf6lc"},"timestamp":"2026-09-28T10:43:40Z","window":"15.535s","containers":[{"name":"adaptive-inventory-service","usage":{"cpu":"1602059n","memory":"286436Ki"}}]}]}
      """;
  private static final String DEPLOYMENT="""
      {"metadata":{"name":"adaptive-inventory-service","annotations":{"kubectl.kubernetes.io/last-applied-configuration":"{\"name\":\"adaptive-inventory-service\"}"}},"spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"adaptive-inventory-service","resources":{"limits":{"cpu":"500m","memory":"512Mi"}}}]}}},"status":{"replicas":1,"readyReplicas":1,"availableReplicas":1}}
      """;
  @Test void nanocoresConvertToCores(){assertEquals(0.002729235,KubernetesReader.nanocoresToCores("2729235n"),1e-12);}
  @Test void metricsApiJsonSelectsInventoryContainerCpu(){assertEquals(0.001602059,KubernetesReader.cpuCoresFromMetrics(METRICS,"adaptive-inventory-service"),1e-12);}
  @Test void metricsApiWorkingSetIsComparedToTheDeploymentLimit(){assertEquals((286436d*1024)/(512d*1024*1024),KubernetesReader.memoryUsageRatioFromMetrics(METRICS,DEPLOYMENT,"adaptive-inventory-service"),1e-12);}
  @Test void deploymentReadinessRequiresDesiredReadyAndAvailableReplicas(){assertTrue(KubernetesReader.deploymentHealthy(DEPLOYMENT));assertFalse(KubernetesReader.deploymentHealthy(DEPLOYMENT.replace("\"readyReplicas\":1","\"readyReplicas\":0")));}
  @Test void missingOrMalformedMetricsRemainUnavailable(){assertTrue(Double.isNaN(KubernetesReader.nanocoresToCores("")));assertTrue(Double.isNaN(KubernetesReader.cpuCoresFromMetrics("{}","adaptive-inventory-service")));assertTrue(Double.isNaN(KubernetesReader.memoryUsageRatioFromMetrics(METRICS,"{}","adaptive-inventory-service")));}
}
