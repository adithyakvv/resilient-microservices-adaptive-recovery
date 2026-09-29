package com.adaptive.recovery;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class KubernetesReaderMitigationResponseTest {
    @Test
    void acceptsOnlySuccessfulExplicitDelayOffResponse() {
        assertTrue(KubernetesReader.confirmsDelayOff(200, "{\"enabled\":false,\"delayMs\":0}"));
        assertTrue(KubernetesReader.confirmsDelayOff(200, "{ \"enabled\" : false, \"delayMs\" : 0 }"));
        assertFalse(KubernetesReader.confirmsDelayOff(503, "{\"enabled\":false,\"delayMs\":0}"));
        assertFalse(KubernetesReader.confirmsDelayOff(200, "{\"enabled\":true,\"delayMs\":0}"));
        assertFalse(KubernetesReader.confirmsDelayOff(200, "{\"enabled\":false,\"delayMs\":20}"));
        assertFalse(KubernetesReader.confirmsDelayOff(200, "not-json"));
    }
}
