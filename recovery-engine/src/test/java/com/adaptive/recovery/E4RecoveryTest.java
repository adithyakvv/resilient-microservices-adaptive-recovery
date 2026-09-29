package com.adaptive.recovery;
import org.junit.jupiter.api.Test;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.jupiter.api.Assertions.*; import static org.mockito.Mockito.*;
class E4RecoveryTest {
  private static E4RecoveryService service(int window,double latency,KubernetesReader k){E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(latency,409,0));return new E4RecoveryService(window,500,mock(PrometheusReader.class),k,store);}
  @Test void previewRequiresFreshPersistentLatencyAndDoesNotRestart(){KubernetesReader k=mock(KubernetesReader.class);RecoveryRecord r=service(3,700,k).evaluate(false);assertEquals(RecoveryDecision.OBSERVE,r.decision());assertFalse(r.actionVerified());verifyNoInteractions(k);}
  @Test void previewRecommendsMitigationButDoesNotDisableDelay(){KubernetesReader k=mock(KubernetesReader.class);E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(700,409,0));E4RecoveryService s=new E4RecoveryService(1,500,mock(PrometheusReader.class),k,store);RecoveryRecord preview=s.evaluate(false);assertEquals(RecoveryDecision.SIMULATED_DELAY_MITIGATION,preview.decision());assertFalse(preview.actionVerified());verify(k,never()).disableOrderDelay();}
  @Test void executeMitigatesOnlyOnceAndCooldownBlocksRepeat(){KubernetesReader k=mock(KubernetesReader.class);when(k.disableOrderDelay()).thenReturn(true);E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(700,409,0));E4RecoveryService s=new E4RecoveryService(1,500,mock(PrometheusReader.class),k,store);RecoveryRecord applied=s.evaluate(true);assertEquals(RecoveryDecision.SIMULATED_DELAY_MITIGATION,applied.decision());assertTrue(applied.actionVerified());assertTrue(applied.reason().contains("Engine mitigation verified"));RecoveryRecord second=s.evaluate(true);assertEquals(RecoveryDecision.OBSERVE,second.decision());verify(k,times(1)).disableOrderDelay();}
  @Test void persistenceWindowRequiresDistinctEvaluations(){KubernetesReader k=mock(KubernetesReader.class);when(k.disableOrderDelay()).thenReturn(true);E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(700,409,0));E4RecoveryService s=new E4RecoveryService(3,500,mock(PrometheusReader.class),k,store);assertEquals(RecoveryDecision.OBSERVE,s.evaluate(true).decision());assertEquals(RecoveryDecision.OBSERVE,s.evaluate(true).decision());assertTrue(s.evaluate(true).actionVerified());verify(k,times(1)).disableOrderDelay();}
  @Test void missingLatencyIsFailSafe(){KubernetesReader k=mock(KubernetesReader.class);assertEquals(RecoveryDecision.FAIL_SAFE,new E4RecoveryService(1,500,mock(PrometheusReader.class),k).evaluate(true).decision());verifyNoInteractions(k);}
  @Test void failedMitigationResponseIsNotVerified(){KubernetesReader k=mock(KubernetesReader.class);when(k.disableOrderDelay()).thenReturn(false);when(k.lastMitigationOutcome()).thenReturn("http=503; body=unavailable; confirmedDelayOff=false");E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(700,409,0));RecoveryRecord r=new E4RecoveryService(1,500,mock(PrometheusReader.class),k,store).evaluate(true);assertEquals(RecoveryDecision.SIMULATED_DELAY_MITIGATION,r.decision());assertFalse(r.actionVerified());assertTrue(r.reason().contains("Engine mitigation not verified"));assertTrue(r.reason().contains("http=503"));verify(k).disableOrderDelay();}
  @Test void successfulFinallyCleanupDoesNotPromoteFailedEngineAction(){KubernetesReader k=mock(KubernetesReader.class);when(k.disableOrderDelay()).thenReturn(false,true);when(k.lastMitigationOutcome()).thenReturn("http=503; body=unavailable; confirmedDelayOff=false");E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(700,409,0));RecoveryRecord action=new E4RecoveryService(1,500,mock(PrometheusReader.class),k,store).evaluate(true);assertFalse(action.actionVerified());assertTrue(k.disableOrderDelay());assertFalse(action.actionVerified(),"Later runner finally cleanup must not be treated as Engine action evidence.");verify(k,times(2)).disableOrderDelay();}
  @Test void laterRunCanActAgainAfterCooldownExpires(){KubernetesReader k=mock(KubernetesReader.class);when(k.disableOrderDelay()).thenReturn(true,true);E4MetricsStore store=new E4MetricsStore();store.publish(new E4MetricsStore.Sample(700,409,0));MutableClock clock=new MutableClock(Instant.parse("2026-09-28T06:00:00Z"));E4RecoveryService s=new E4RecoveryService(1,500,mock(PrometheusReader.class),k,store,clock);assertTrue(s.evaluate(true).actionVerified());clock.advanceSeconds(61);assertTrue(s.evaluate(true).actionVerified(),"Expired cooldown must re-arm E4; a permanent lifetime flag must not block later runs.");verify(k,times(2)).disableOrderDelay();}
  @Test void restartCommandTargetsOnlyOrderDeployment(){assertArrayEquals(new String[]{"kubectl","rollout","restart","deployment/adaptive-order-service","-n","ns"},KubernetesReader.buildOrderRestartCommand("kubectl","ns"));}
  @Test void replacementReadyPodUidIsVerified(){
    String json="{\"items\":[{\"metadata\":{\"uid\":\"new-uid\"},\"status\":{\"containerStatuses\":[{\"ready\":true}]}}]}";
    assertTrue(KubernetesReader.hasDifferentReadyPod("old-uid",json));
  }
  @Test void timeoutWithSameReadyPodUidIsNotVerifiedAsRestart(){
    String json="{\"items\":[{\"metadata\":{\"uid\":\"old-uid\"},\"status\":{\"containerStatuses\":[{\"ready\":true}]}}]}";
    assertFalse(KubernetesReader.hasDifferentReadyPod("old-uid",json));
  }
  private static final class MutableClock extends Clock {
    private final AtomicReference<Instant> instant;
    MutableClock(Instant initial){instant=new AtomicReference<>(initial);}
    void advanceSeconds(long seconds){instant.updateAndGet(value->value.plusSeconds(seconds));}
    @Override public ZoneId getZone(){return ZoneId.of("UTC");}
    @Override public Clock withZone(ZoneId zone){return this;}
    @Override public Instant instant(){return instant.get();}
  }
}
