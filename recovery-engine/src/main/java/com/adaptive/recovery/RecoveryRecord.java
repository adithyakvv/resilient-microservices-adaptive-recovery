package com.adaptive.recovery;
import java.time.Instant;
public record RecoveryRecord(Instant at, String service, RecoveryDecision decision, String reason, Signals signals, boolean actionVerified) {}
