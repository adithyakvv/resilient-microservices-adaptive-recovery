package com.adaptive.order;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class E4FaultStateTest {
    @Test void defaultsOffAndCanBeBoundedlyToggled() {
        E4FaultState state = new E4FaultState();
        assertFalse(state.enabled());
        assertTrue(state.set(true));
        assertTrue(state.enabled());
        assertFalse(state.set(false));
        assertFalse(state.enabled());
    }
}
