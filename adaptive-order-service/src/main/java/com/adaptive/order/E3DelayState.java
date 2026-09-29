package com.adaptive.order;

import org.springframework.stereotype.Component;

import java.util.concurrent.atomic.AtomicInteger;

/** E3-only demo switch; disabled by default and bounded to 1500 ms.
 * Automatic TTL was removed because it could not be verified in the running
 * Docker Desktop image; callers must explicitly disable the switch. */
@Component
class E3DelayState {
    private final AtomicInteger delayMs = new AtomicInteger(0);

    int delayMs() {
        return delayMs.get();
    }

    void set(boolean enabled, int requestedMs) {
        if (!enabled) {
            delayMs.set(0);
            return;
        }
        if (requestedMs < 1 || requestedMs > 1500) {
            throw new IllegalArgumentException("E3 delay must be between 1 and 1500 ms");
        }
        delayMs.set(requestedMs);
    }
}
