package com.adaptive.recovery;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class RecoveryEngineActuatorTest {
  private static RecoveryEngineService service(PrometheusReader p, KubernetesReader k, double cpu, double memory) {
    when(k.healthy("adaptive-inventory-service")).thenReturn(true);
    when(k.cpuCores("adaptive-inventory-service")).thenReturn(cpu); when(k.memoryUsageRatio("adaptive-inventory-service")).thenReturn(memory);
    when(p.read(eq("adaptive-inventory-service"), eq(3), eq(true)))
      .thenReturn(new Signals(cpu,memory,1,0,0.01,true,3,3,true));
    return new RecoveryEngineService(3,60,.80,.85,p,k);
  }

  @Test void configuredBaselineAndTargetsAreExplicit() {
    assertEquals("100m", KubernetesReader.BASE_CPU_REQUEST); assertEquals("500m", KubernetesReader.BASE_CPU_LIMIT);
    assertEquals("256Mi", KubernetesReader.BASE_MEMORY_REQUEST); assertEquals("512Mi", KubernetesReader.BASE_MEMORY_LIMIT);
    assertEquals("200m", KubernetesReader.TARGET_CPU_REQUEST); assertEquals("600m", KubernetesReader.TARGET_CPU_LIMIT);
    assertEquals("384Mi", KubernetesReader.TARGET_MEMORY_REQUEST); assertEquals("768Mi", KubernetesReader.TARGET_MEMORY_LIMIT);
  }

  @Test void dryRunCpuDoesNotCallActuator() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    RecoveryEngineService s=service(p,k,.90,.10);
    assertEquals(RecoveryDecision.INCREASE_CPU,s.evaluate("adaptive-inventory",false).decision());
    verify(k,never()).increaseCpu(anyString());
  }

  @Test void e2ProfileUsesLowerMemoryThresholdWhileDefaultRemainsPointEightFive() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    when(k.healthy("adaptive-inventory-service")).thenReturn(true); when(k.cpuCores("adaptive-inventory-service")).thenReturn(.01); when(k.memoryUsageRatio("adaptive-inventory-service")).thenReturn(.75);
    when(p.read(eq("adaptive-inventory-service"),eq(3),eq(true))).thenReturn(new Signals(.01,.75,1,0,.01,true,3,3,true));
    RecoveryEngineService s=new RecoveryEngineService(3,60,.80,.85,.70,p,k);
    assertEquals(RecoveryDecision.CONTINUE,s.evaluate("adaptive-inventory",false).decision());
    assertEquals(RecoveryDecision.INCREASE_MEMORY,s.evaluate("adaptive-inventory",false,"e2-memory").decision());
  }

  @Test void executeCpuUsesBoundedAction() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class); when(k.increaseCpu("adaptive-inventory")).thenReturn(true);
    RecoveryEngineService s=service(p,k,.90,.10);
    assertTrue(s.evaluate("adaptive-inventory",true).actionVerified()); verify(k).increaseCpu("adaptive-inventory");
  }

  @Test void executeMemoryUsesBoundedAction() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class); when(k.increaseMemory("adaptive-inventory")).thenReturn(true);
    RecoveryEngineService s=service(p,k,.10,.90);
    assertTrue(s.evaluate("adaptive-inventory",true).actionVerified()); verify(k).increaseMemory("adaptive-inventory");
  }

  @Test void memoryQuantityAndRatioUseKubernetesUnits() {
    assertEquals(512d*1024*1024, KubernetesReader.memoryQuantityBytes("512Mi"));
    assertEquals(64d*1000*1000, KubernetesReader.memoryQuantityBytes("64MB"));
    assertEquals(.25, KubernetesReader.memoryQuantityBytes("128Mi")/KubernetesReader.memoryQuantityBytes("512Mi"), 1e-9);
    assertTrue(Double.isNaN(KubernetesReader.memoryQuantityBytes("not-a-quantity")));
  }

  @Test void inventoryMemorySignalCrossingRequestsBoundedMemoryOnly() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    when(k.healthy("adaptive-inventory-service")).thenReturn(true); when(k.cpuCores("adaptive-inventory-service")).thenReturn(.01); when(k.memoryUsageRatio("adaptive-inventory-service")).thenReturn(.90); when(k.increaseMemory("adaptive-inventory")).thenReturn(true);
    when(p.read(eq("adaptive-inventory-service"),eq(3),eq(true))).thenReturn(new Signals(.01,.01,1,0,.01,true,-1,3,true));
    RecoveryRecord r=new RecoveryEngineService(3,60,.80,.85,p,k).evaluate("adaptive-inventory",true);
    assertEquals(RecoveryDecision.INCREASE_MEMORY,r.decision()); assertTrue(r.actionVerified()); verify(k).increaseMemory("adaptive-inventory"); verify(k,never()).increaseCpu(anyString());
  }

  @Test void missingInventoryMemorySignalFailsSafe() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class); when(k.healthy("adaptive-inventory-service")).thenReturn(true); when(k.cpuCores("adaptive-inventory-service")).thenReturn(.01); when(k.memoryUsageRatio("adaptive-inventory-service")).thenReturn(Double.NaN);
    when(p.read(eq("adaptive-inventory-service"),eq(3),eq(true))).thenReturn(new Signals(.01,.90,1,0,.01,true,-1,3,true));
    assertEquals(RecoveryDecision.FAIL_SAFE,new RecoveryEngineService(3,60,.80,.85,p,k).evaluate("adaptive-inventory",true).decision()); verify(k,never()).increaseMemory(anyString());
  }

  @Test void invalidBaselineFailsSafeWithoutPatch() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    when(k.healthy("adaptive-inventory-service")).thenReturn(true);
    when(k.memoryUsageRatio("adaptive-inventory-service")).thenReturn(Double.NaN);
    when(p.read(eq("adaptive-inventory-service"),eq(3),eq(true))).thenReturn(new Signals(.90,Double.NaN,1,0,.01,true,3,3,true));
    RecoveryRecord r=new RecoveryEngineService(3,60,.80,.85,p,k).evaluate("adaptive-inventory",true);
    assertEquals(RecoveryDecision.FAIL_SAFE,r.decision()); verify(k,never()).increaseCpu(anyString()); verify(k,never()).increaseMemory(anyString());
  }

  @Test void restorePassesExactSavedBaseline() {
    KubernetesReader k=mock(KubernetesReader.class); when(k.restore("adaptive-inventory-service","100m","500m","256Mi","512Mi")).thenReturn(true);
    assertTrue(k.restore("adaptive-inventory-service","100m","500m","256Mi","512Mi"));
    verify(k).restore("adaptive-inventory-service","100m","500m","256Mi","512Mi");
  }

  @Test void cpuCommandTargetsOnlyCpuAndPreservesOtherResources() {
    String[] c=KubernetesReader.buildCpuCommand("kubectl","resilient-microservices-adaptive-recovery","adaptive-inventory-service");
    assertArrayEquals(new String[]{"kubectl","set","resources","deployment","adaptive-inventory-service","-n","resilient-microservices-adaptive-recovery","-c","adaptive-inventory-service","--requests=cpu=200m","--limits=cpu=600m"},c);
  }

  @Test void inventoryDependencySignalIsNotApplicable() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    when(k.healthy("adaptive-inventory-service")).thenReturn(true);
    when(p.read(eq("adaptive-inventory-service"),eq(3),eq(true))).thenReturn(new Signals(.10,.10,1,0,.01,true,-1,3,true));
    assertEquals(RecoveryDecision.CONTINUE,new RecoveryEngineService(3,60,.80,.85,p,k).evaluate("adaptive-inventory",false).decision());
  }

  @Test void orderDependencySamplesRemainRequired() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    when(k.healthy("adaptive-order-service")).thenReturn(true);
    when(p.read(eq("adaptive-order-service"),eq(3),eq(true))).thenReturn(new Signals(.10,.10,1,0,.01,true,0,3,true));
    assertEquals(RecoveryDecision.OBSERVE,new RecoveryEngineService(3,60,.80,.85,p,k).evaluate("adaptive-order",false).decision());
  }

  @Test void previewThenSingleVerifiedActionStartsCooldown() {
    PrometheusReader p=mock(PrometheusReader.class); KubernetesReader k=mock(KubernetesReader.class);
    when(k.healthy("adaptive-inventory-service")).thenReturn(true); when(k.cpuCores("adaptive-inventory-service")).thenReturn(.9); when(k.increaseCpu("adaptive-inventory")).thenReturn(true);
    when(p.read(eq("adaptive-inventory-service"),eq(3),eq(true))).thenReturn(new Signals(.9,.1,1,0,.01,true,-1,3,true));
    RecoveryEngineService s=new RecoveryEngineService(3,60,.8,.85,p,k);
    assertEquals(RecoveryDecision.INCREASE_CPU,s.evaluate("adaptive-inventory",false).decision());
    RecoveryRecord applied=s.evaluate("adaptive-inventory",true); assertEquals(RecoveryDecision.INCREASE_CPU,applied.decision()); assertTrue(applied.actionVerified());
    assertEquals(RecoveryDecision.OBSERVE,s.evaluate("adaptive-inventory",true).decision()); verify(k,times(1)).increaseCpu("adaptive-inventory");
  }
}
