package com.adaptive.recovery;

import java.time.Instant;
import java.time.Clock;
import java.util.ArrayDeque;
import java.util.Deque;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/** E4-only actuator. The normal Inventory CPU/memory decision path is untouched. */
@Service
class E4RecoveryService {
    private final PrometheusReader prometheus;
    private final E4MetricsStore samples;
    private final KubernetesReader kubernetes;
    private final int window;
    private final double threshold;
    private final Deque<Instant> freshErrors = new ArrayDeque<>();
    private volatile Instant lastAction;
    private final Clock clock;

    E4RecoveryService(int window, double threshold, PrometheusReader prometheus, KubernetesReader kubernetes) {
        this(window, threshold, prometheus, kubernetes, new E4MetricsStore(), Clock.systemUTC());
    }

    @org.springframework.beans.factory.annotation.Autowired E4RecoveryService(@Value("${recovery.persistence-window}") int window,
                      @Value("${recovery.e4-latency-threshold-ms:500}") double threshold,
                      PrometheusReader prometheus, KubernetesReader kubernetes, E4MetricsStore samples) {
        this(window, threshold, prometheus, kubernetes, samples, Clock.systemUTC());
    }

    E4RecoveryService(int window, double threshold, PrometheusReader prometheus, KubernetesReader kubernetes,
                      E4MetricsStore samples, Clock clock) {
        this.window = window; this.threshold = threshold; this.prometheus = prometheus;
        this.kubernetes = kubernetes; this.samples = samples; this.clock = clock;
    }

    synchronized RecoveryRecord evaluate(boolean execute) {
        E4MetricsStore.Sample sample = samples.latest();
        double latency = sample == null ? Double.NaN : sample.latencyMs();
        int persistence = 0;
        if (Double.isFinite(latency) && latency >= threshold) { freshErrors.addLast(Instant.now(clock)); }
        else { freshErrors.clear(); }
        while (freshErrors.size() > window) freshErrors.removeFirst();
        persistence = freshErrors.size();
        Signals signals = new Signals(Double.NaN, Double.NaN, 1, latency, latency, true, -1, persistence, true);
        RecoveryDecision decision; String reason; boolean verified = false;
        if (!Double.isFinite(latency)) { decision = RecoveryDecision.FAIL_SAFE; reason = "E4 Order→Inventory latency signal unavailable"; }
        else if (signals.persistenceSamples() < window) { decision = RecoveryDecision.OBSERVE; reason = "E4 latency threshold persistence incomplete (threshold=" + threshold + " ms)"; }
        else if (lastAction != null && lastAction.plusSeconds(60).isAfter(Instant.now(clock))) { decision = RecoveryDecision.OBSERVE; reason = "E4 simulated-delay mitigation cooldown active"; }
        else {
            decision = RecoveryDecision.SIMULATED_DELAY_MITIGATION;
            reason = "E4 Order→Inventory latency threshold sustained (threshold=" + threshold + " ms); simulated-delay mitigation requires explicit execute=true";
            if (execute) {
                verified = kubernetes.disableOrderDelay();
                // Cooldown limits repeated attempts, but a prior attempt must not permanently
                // consume the actuator. A later run may act after the cooldown expires.
                lastAction = Instant.now(clock);
                reason += "; Engine mitigation " + (verified ? "verified" : "not verified") + "; " + kubernetes.lastMitigationOutcome();
            }
        }
        return new RecoveryRecord(Instant.now(clock), "adaptive-order-service", decision, reason, signals, verified);
    }
}
