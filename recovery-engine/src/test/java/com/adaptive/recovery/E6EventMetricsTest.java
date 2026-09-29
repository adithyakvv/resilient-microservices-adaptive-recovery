package com.adaptive.recovery;

import static org.junit.jupiter.api.Assertions.*;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.web.server.ResponseStatusException;

class E6EventMetricsTest {
    private static final String RUN_ONE = "E6-20260929-014919+0530";
    private static final String RUN_TWO = "E6-20260929-020000+0530";
    private static final String RUNNER = "local-fixed-e6";

    @Test void observedEventsRequireEvidenceAndResetBetweenRuns() {
        RecoveryController controller = new RecoveryController(null);
        assertTrue(controller.e2Metrics().contains("adaptive_recovery_e6_interruption_observed NaN"));
        assertThrows(ResponseStatusException.class, () -> controller.observeE6Event(RUNNER,
                Map.of("runId", RUN_ONE, "event", "product-interruption-observed", "ready", false, "health", false)));
        assertThrows(ResponseStatusException.class, () -> controller.startE6Events(null, Map.of("runId", RUN_ONE)));
        assertThrows(ResponseStatusException.class, () -> controller.startE6Events(RUNNER, Map.of("runId", "arbitrary")));

        controller.e6Sample(Map.of("productReady", 1, "replacementVerified", 0, "podKillActive", 0));
        controller.startE6Events(RUNNER, Map.of("runId", RUN_ONE));
        assertMetric(controller, "adaptive_recovery_e6_interruption_observed", "0.0");
        assertMetric(controller, "adaptive_recovery_e6_healthy_replacement_verified", "0.0");
        assertMetric(controller, "adaptive_recovery_e6_product_ready", "1.0");
        assertThrows(ResponseStatusException.class, () -> controller.observeE6Event(RUNNER,
                Map.of("runId", RUN_ONE, "event", "product-interruption-observed", "ready", true, "health", true)));
        assertMetric(controller, "adaptive_recovery_e6_interruption_observed", "0.0");

        controller.observeE6Event(RUNNER, Map.of("runId", RUN_ONE,
                "event", "product-interruption-observed", "ready", false, "health", false));
        assertMetric(controller, "adaptive_recovery_e6_interruption_observed", "1.0");
        assertMetric(controller, "adaptive_recovery_e6_healthy_replacement_verified", "0.0");
        assertThrows(ResponseStatusException.class, () -> controller.observeE6Event(RUNNER,
                Map.of("runId", RUN_ONE, "event", "healthy-replacement-verified", "ready", true,
                        "health", true, "baselineUid", "same", "replacementUid", "same")));
        assertThrows(ResponseStatusException.class, () -> controller.observeE6Event(RUNNER,
                Map.of("runId", RUN_ONE, "event", "healthy-replacement-verified", "ready", true,
                        "health", false, "baselineUid", "old", "replacementUid", "new")));
        assertMetric(controller, "adaptive_recovery_e6_healthy_replacement_verified", "0.0");

        controller.observeE6Event(RUNNER, Map.of("runId", RUN_ONE,
                "event", "healthy-replacement-verified", "ready", true, "health", true,
                "baselineUid", "old", "replacementUid", "new"));
        assertMetric(controller, "adaptive_recovery_e6_healthy_replacement_verified", "1.0");

        controller.startE6Events(RUNNER, Map.of("runId", RUN_TWO));
        assertMetric(controller, "adaptive_recovery_e6_interruption_observed", "0.0");
        assertMetric(controller, "adaptive_recovery_e6_healthy_replacement_verified", "0.0");
        assertMetric(controller, "adaptive_recovery_e6_product_ready", "1.0");
        assertThrows(ResponseStatusException.class, () -> controller.observeE6Event(RUNNER,
                Map.of("runId", RUN_ONE, "event", "product-interruption-observed", "ready", false, "health", false)),
                "A late event from the first run cannot contaminate the second");
        assertMetric(controller, "adaptive_recovery_e6_interruption_observed", "0.0");
    }

    private static void assertMetric(RecoveryController controller, String name, String value) {
        assertTrue(controller.e2Metrics().contains("\n" + name + " " + value + "\n"), name + " should be " + value);
    }
}
