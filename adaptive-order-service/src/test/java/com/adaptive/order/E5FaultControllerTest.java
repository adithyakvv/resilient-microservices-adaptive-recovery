package com.adaptive.order;

import static org.junit.jupiter.api.Assertions.*;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;

class E5FaultControllerTest {
    @Test void disabledProbeIsHealthyAndEnableReturns500WithoutPersistence() {
        E5FaultState state = new E5FaultState();
        E5FaultController controller = new E5FaultController(state);
        assertEquals(HttpStatus.OK, controller.probe().getStatusCode());
        assertFalse(state.enabled());
        assertEquals(Boolean.TRUE, controller.fault(Map.of("enabled", true)).get("enabled"));
        assertEquals(HttpStatus.INTERNAL_SERVER_ERROR, controller.probe().getStatusCode());
        assertEquals(Boolean.FALSE, controller.fault(Map.of("enabled", false)).get("enabled"));
        assertEquals(HttpStatus.OK, controller.probe().getStatusCode());
    }
}
