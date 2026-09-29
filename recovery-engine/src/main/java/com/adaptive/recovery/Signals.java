package com.adaptive.recovery;
public record Signals(double cpu, double memory, double readiness, double httpErrors, double latency, boolean dependencyUp, int dependencySuccesses, int persistenceSamples, boolean kubernetesHealthy) {}
