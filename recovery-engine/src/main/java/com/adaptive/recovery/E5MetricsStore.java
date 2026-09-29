package com.adaptive.recovery;

import java.time.Instant;
import java.util.concurrent.atomic.AtomicReference;
import org.springframework.stereotype.Component;

/** Last validated, timestamped response from the real E5 probe. */
@Component
class E5MetricsStore {
    record Sample(Instant at, int status, boolean fresh) {}
    private final AtomicReference<Sample> latest = new AtomicReference<>();
    synchronized void resetForRun() { latest.set(null); }
    synchronized boolean publish(Instant at, int status) {
        if (at == null || status < 100 || status > 599) return false;
        Sample old = latest.get();
        if (old != null && !at.isAfter(old.at())) return false;
        latest.set(new Sample(at, status, true));
        return true;
    }
    Sample latest() { return latest.get(); }
}
