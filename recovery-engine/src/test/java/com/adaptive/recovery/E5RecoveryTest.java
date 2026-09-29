package com.adaptive.recovery;

import static org.junit.jupiter.api.Assertions.*;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class E5RecoveryTest {
    @Test void noErrorsContinueAndThresholdPreviewIsSimulationOnly() {
        E5MetricsStore store = new E5MetricsStore();
        E5RecoveryService service = new E5RecoveryService(3, 500, new KubernetesReader("n", "kubectl", "http://127.0.0.1:18083/api/internal/e3-delay"), store);
        store.publish(Instant.parse("2026-09-27T09:59:59Z"), 200);
        assertEquals(RecoveryDecision.CONTINUE, service.evaluate(false).decision());
        store.publish(Instant.parse("2026-09-27T10:00:00Z"), 500); service.evaluate(false);
        store.publish(Instant.parse("2026-09-27T10:00:01Z"), 500); service.evaluate(false);
        store.publish(Instant.parse("2026-09-27T10:00:02Z"), 500);
        var preview = service.evaluate(false);
        assertEquals(RecoveryDecision.SIMULATED_RESTART, preview.decision());
        assertFalse(preview.actionVerified());
        assertTrue(preview.reason().contains("no service was restarted"));
    }
    @Test void oneAndTwoFresh500sObserveThenThreeRecommendWithoutPreviewRestart() {
        E5MetricsStore store = new E5MetricsStore();
        E5RecoveryService service = new E5RecoveryService(3, 500, new KubernetesReader("n", "kubectl", "http://127.0.0.1:18083/api/internal/e3-delay"), store);
        store.publish(Instant.parse("2026-09-27T10:00:00Z"), 500);
        assertEquals(RecoveryDecision.OBSERVE, service.evaluate(false).decision());
        store.publish(Instant.parse("2026-09-27T10:00:01Z"), 500);
        assertEquals(RecoveryDecision.OBSERVE, service.evaluate(false).decision());
        store.publish(Instant.parse("2026-09-27T10:00:02Z"), 500);
        assertEquals(RecoveryDecision.SIMULATED_RESTART, service.evaluate(false).decision());
        var applied = service.evaluate(true);
        assertEquals(RecoveryDecision.SIMULATED_RESTART, applied.decision());
        assertTrue(applied.actionVerified());
        assertTrue(applied.reason().contains("no service was restarted"));
    }

    @Test void repeatedTimestampIsNotAThirdFreshObservation() {
        E5MetricsStore store = new E5MetricsStore();
        Instant t = Instant.parse("2026-09-27T10:00:00Z");
        assertTrue(store.publish(t, 500)); assertFalse(store.publish(t, 500));
    }

    @Test void twoSuccessiveRunsNeverShareCountOrRecordedAction() {
        E5MetricsStore store = new E5MetricsStore();
        E5RecoveryService service = new E5RecoveryService(3, 500,
                new KubernetesReader("n", "kubectl", "http://127.0.0.1:18083/api/internal/e3-delay"), store);
        RecoveryController controller = new RecoveryController(null, null, null, service, store);
        assertThrows(org.springframework.web.server.ResponseStatusException.class, () -> controller.startE5(null));

        controller.startE5("local-fixed-e5");
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_http_500_consecutive 0.0"));
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_simulated_action 0.0"));
        Instant base = Instant.parse("2026-09-29T00:00:00Z");
        controller.e5Sample(java.util.Map.of("httpStatus", 200, "timestamp", base.toString()));
        assertEquals(RecoveryDecision.CONTINUE, controller.evaluateE5(false).decision());
        for (int i = 1; i <= 3; i++) {
            controller.e5Sample(java.util.Map.of("httpStatus", 500, "timestamp", base.plusSeconds(i).toString()));
            RecoveryRecord preview = controller.evaluateE5(false);
            assertEquals(i < 3 ? RecoveryDecision.OBSERVE : RecoveryDecision.SIMULATED_RESTART, preview.decision());
            assertEquals(i, preview.signals().persistenceSamples());
            assertFalse(preview.actionVerified());
            assertEquals(i, controller.evaluateE5(false).signals().persistenceSamples(),
                    "Repeated evaluation of the same sample must not increase persistence");
            assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_simulated_action 0.0"));
        }
        RecoveryRecord firstAction = controller.evaluateE5(true);
        assertTrue(firstAction.actionVerified());
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_simulated_action 1.0"));
        assertFalse(controller.evaluateE5(false).actionVerified());
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_simulated_action 1.0"),
                "A later preview must not erase the current run's recorded action");
        controller.e5Sample(java.util.Map.of("httpStatus", 200, "timestamp", base.plusSeconds(4).toString()));
        assertEquals(RecoveryDecision.CONTINUE, controller.evaluateE5(false).decision());
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_http_500_consecutive 0.0"));
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_simulated_action 1.0"),
                "The recorded action stays visible through fault-off cleanup in the same run");

        controller.startE5("local-fixed-e5");
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_http_500_consecutive 0.0"));
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e5_simulated_action 0.0"));
        controller.e5Sample(java.util.Map.of("httpStatus", 200, "timestamp", base.plusSeconds(10).toString()));
        assertEquals(RecoveryDecision.CONTINUE, controller.evaluateE5(false).decision());
        controller.e5Sample(java.util.Map.of("httpStatus", 500, "timestamp", base.plusSeconds(11).toString()));
        RecoveryRecord secondOne = controller.evaluateE5(false);
        assertEquals(RecoveryDecision.OBSERVE, secondOne.decision());
        assertEquals(1, secondOne.signals().persistenceSamples());
        assertFalse(controller.evaluateE5(true).actionVerified(), "One fresh 500 must never record action");
        controller.e5Sample(java.util.Map.of("httpStatus", 500, "timestamp", base.plusSeconds(12).toString()));
        assertEquals(RecoveryDecision.OBSERVE, controller.evaluateE5(false).decision());
        controller.e5Sample(java.util.Map.of("httpStatus", 500, "timestamp", base.plusSeconds(13).toString()));
        assertEquals(RecoveryDecision.SIMULATED_RESTART, controller.evaluateE5(false).decision());
        assertTrue(controller.evaluateE5(true).actionVerified(), "A second run can independently record its own decision");
    }
}
