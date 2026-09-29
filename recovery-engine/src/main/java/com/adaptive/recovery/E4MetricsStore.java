package com.adaptive.recovery;

import java.util.concurrent.atomic.AtomicReference;
import org.springframework.stereotype.Component;

/** Fixed, E4-only in-memory handoff. Prometheus scrapes the same values for Grafana. */
@Component
class E4MetricsStore {
    record Sample(double latencyMs, double probeStatus, double restartVerified) {}
    private final AtomicReference<Sample> latest = new AtomicReference<>();
    void publish(Sample sample) { latest.set(sample); }
    Sample latest() { return latest.get(); }
}
