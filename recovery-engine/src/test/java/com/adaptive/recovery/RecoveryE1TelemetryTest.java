package com.adaptive.recovery;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.web.server.ResponseStatusException;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class RecoveryE1TelemetryTest {
    @Test void highStressThenFreshLowerSampleRetainsSourceTime() {
        RecoveryController controller = new RecoveryController(mock(RecoveryEngineService.class));
        controller.e1Sample(Map.of("cpuCores", 0.498, "sourceTimestamp", "2026-09-29T02:14:00Z"));
        controller.e1Sample(Map.of("cpuCores", 0.002, "sourceTimestamp", "2026-09-29T02:15:00Z"));
        String metrics = controller.e2Metrics();
        assertTrue(metrics.contains("adaptive_recovery_e1_cpu_cores 0.002"));
        assertTrue(metrics.contains("adaptive_recovery_e1_cpu_source_timestamp_seconds 1.7906481E9"));
    }

    @Test void missingFinalSampleInvalidatesHeldStressValueWithoutPublishingZero() {
        RecoveryController controller = new RecoveryController(mock(RecoveryEngineService.class));
        controller.e1Sample(Map.of("cpuCores", 0.498, "sourceTimestamp", "2026-09-29T02:14:00Z"));
        controller.e1Unavailable();
        String metrics = controller.e2Metrics();
        assertTrue(metrics.contains("adaptive_recovery_e1_cpu_cores NaN"));
        assertTrue(metrics.contains("adaptive_recovery_e1_cpu_source_timestamp_seconds NaN"));
        assertFalse(metrics.contains("adaptive_recovery_e1_cpu_cores 0.0"));
        assertThrows(ResponseStatusException.class,
            () -> controller.e1Sample(Map.of("cpuCores", 0.002, "sourceTimestamp", "not-a-time")));
    }
}
