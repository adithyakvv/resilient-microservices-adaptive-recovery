package com.adaptive.recovery;

import java.time.Instant;
import java.util.ArrayDeque;
import java.util.Deque;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

/** E5-only persistence gate for a simulation-only restart recommendation. */
@Service
class E5RecoveryService {
    private final KubernetesReader kubernetes;
    private final E5MetricsStore samples;
    private final int persistence;
    private final double threshold;
    private final Deque<Instant> fresh500 = new ArrayDeque<>();
    private boolean acted;
    private Instant lastAction;
    private Instant lastEvaluatedSample;

    E5RecoveryService(int persistence, double threshold, KubernetesReader kubernetes, E5MetricsStore samples) {
        this.persistence = persistence; this.threshold = threshold; this.kubernetes = kubernetes; this.samples = samples;
    }

    @org.springframework.beans.factory.annotation.Autowired E5RecoveryService(
            @Value("${recovery.e5-persistence-window:3}") int persistence,
            @Value("${recovery.e5-http500-threshold:500}") double threshold,
            KubernetesReader kubernetes, E5MetricsStore samples,
            @Value("${recovery.e5-profile:e5-http500}") String profile) {
        this(persistence, threshold, kubernetes, samples);
    }

    synchronized RecoveryRecord evaluate(boolean execute) {
        E5MetricsStore.Sample s = samples.latest();
        if (s == null || !s.fresh()) {
            return record(RecoveryDecision.FAIL_SAFE, "E5 HTTP response signal unavailable", 0);
        }
        if (lastEvaluatedSample == null || s.at().isAfter(lastEvaluatedSample)) {
            lastEvaluatedSample = s.at();
            if (s.status() == 500) fresh500.addLast(s.at()); else fresh500.clear();
        }
        while (fresh500.size() > persistence) fresh500.removeFirst();
        int count = fresh500.size();
        Signals signals = new Signals(Double.NaN, Double.NaN, 1, Double.NaN,
                Double.NaN, true, -1, count, true);
        if (count < persistence) return new RecoveryRecord(Instant.now(), "adaptive-order-service",
                count == 0 ? RecoveryDecision.CONTINUE : RecoveryDecision.OBSERVE,
                count == 0 ? "E5 baseline has no HTTP 500 responses" : "E5 HTTP 500 rise observed below simulated restart persistence threshold (" + count + "/" + persistence + ")", signals, false);
        if (acted && lastAction != null && lastAction.plusSeconds(60).isAfter(Instant.now())) {
            return new RecoveryRecord(Instant.now(), "adaptive-order-service", RecoveryDecision.OBSERVE,
                    "E5 simulated restart cooldown active; no service was restarted", signals, false);
        }
        if (execute && !acted) {
            acted = true;
            lastAction = Instant.now();
            return new RecoveryRecord(Instant.now(), "adaptive-order-service", RecoveryDecision.SIMULATED_RESTART,
                    "E5 persistent HTTP 500 threshold reached; simulated restart action recorded — no service was restarted", signals, true);
        }
        return new RecoveryRecord(Instant.now(), "adaptive-order-service", RecoveryDecision.SIMULATED_RESTART,
                "E5 persistent HTTP 500 threshold reached; simulated restart recommendation — no service was restarted", signals, false);
    }

    synchronized void beginRun() {
        fresh500.clear();
        acted = false;
        lastAction = null;
        lastEvaluatedSample = null;
        samples.resetForRun();
    }

    private RecoveryRecord record(RecoveryDecision d, String reason, int count) {
        return new RecoveryRecord(Instant.now(), "adaptive-order-service", d, reason,
                new Signals(Double.NaN, Double.NaN, 1, Double.NaN, Double.NaN, true, -1, count, true), false);
    }
}
