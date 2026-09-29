package com.adaptive.order;

import java.util.concurrent.atomic.AtomicBoolean;
import org.springframework.stereotype.Component;

/** E4-only in-memory fault. A process restart always returns it to false. */
@Component
class E4FaultState {
    private final AtomicBoolean enabled = new AtomicBoolean(false);

    boolean enabled() { return enabled.get(); }
    boolean set(boolean value) { enabled.set(value); return value; }
}
