package com.adaptive.recovery;
import org.junit.jupiter.api.Test; import static org.junit.jupiter.api.Assertions.*;
class RecoveryDecisionTest { @Test void enumContainsBoundedStates(){ assertEquals(RecoveryDecision.FAIL_SAFE,RecoveryDecision.valueOf("FAIL_SAFE")); assertEquals(RecoveryDecision.INCREASE_CPU,RecoveryDecision.valueOf("INCREASE_CPU")); assertEquals(RecoveryDecision.INCREASE_MEMORY,RecoveryDecision.valueOf("INCREASE_MEMORY")); } }
