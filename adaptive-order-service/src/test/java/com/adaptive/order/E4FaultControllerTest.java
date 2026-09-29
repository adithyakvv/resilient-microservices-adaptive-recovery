package com.adaptive.order;

import org.junit.jupiter.api.Test;
import org.springframework.http.ResponseEntity;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;

class E4FaultControllerTest {
  @Test void probeReturns500OnlyWhenFaultEnabledAndDoesNotNeedPersistence() {
    E4FaultState state=new E4FaultState(); E4FaultController c=new E4FaultController(state);
    assertEquals(200,c.probe().getStatusCode().value());
    c.fault(Map.of("enabled",true));
    ResponseEntity<Map<String,Object>> bad=c.probe(); assertEquals(500,bad.getStatusCode().value()); assertEquals("E4_ORDER_HTTP_500",bad.getBody().get("fault"));
    c.fault(Map.of("enabled",false)); assertEquals(200,c.probe().getStatusCode().value());
  }
}
