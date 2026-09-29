package com.adaptive.order;

import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.stereotype.Component;

/** E5-only in-memory fault; process restart returns it to the safe default. */
@Component
class E5FaultState {
    private final AtomicBoolean enabled = new AtomicBoolean(false);
    boolean set(boolean value) { enabled.set(value); return enabled.get(); }
    boolean enabled() { return enabled.get(); }
}
