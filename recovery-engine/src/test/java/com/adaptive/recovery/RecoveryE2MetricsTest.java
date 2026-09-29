package com.adaptive.recovery;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class RecoveryE2MetricsTest {
  private RecoveryRecord record(RecoveryDecision d, boolean verified){return new RecoveryRecord(Instant.now(),"adaptive-inventory-service",d,"test",new Signals(.01,.75,1,0,.01,true,3,3,true),verified);}
  @Test void onlyVerifiedE2ExecuteIncrementsCumulativeCounter(){
    RecoveryEngineService service=mock(RecoveryEngineService.class); RecoveryController c=new RecoveryController(service);
    when(service.evaluate(anyString(),anyBoolean(),anyString())).thenReturn(record(RecoveryDecision.INCREASE_MEMORY,false),record(RecoveryDecision.INCREASE_MEMORY,false),record(RecoveryDecision.INCREASE_MEMORY,true),record(RecoveryDecision.OBSERVE,false),record(RecoveryDecision.INCREASE_MEMORY,false));
    c.evaluate("adaptive-inventory-service",false,"e2-memory"); c.evaluate("adaptive-inventory-service",true,"e2-memory"); c.evaluate("adaptive-inventory-service",true,"e2-memory"); c.evaluate("adaptive-inventory-service",false,"e2-memory"); c.evaluate("adaptive-inventory-service",false,null);
    String metrics=c.e2Metrics(); assertTrue(metrics.contains("adaptive_recovery_e2_verified_actions_total 1")); assertTrue(metrics.contains("adaptive_recovery_e2_action_verified 0"));
  }
}
