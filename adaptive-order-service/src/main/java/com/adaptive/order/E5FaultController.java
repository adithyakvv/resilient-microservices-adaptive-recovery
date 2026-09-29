package com.adaptive.order;

import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/** Dedicated side-effect-free E5 probe and fixed enable/disable control. */
@RestController
@RequestMapping("/api/internal/e5")
class E5FaultController {
    private final E5FaultState state;
    E5FaultController(E5FaultState state) { this.state = state; }

    @PostMapping("/fault")
    Map<String, Object> fault(@RequestBody Map<String, Object> body) {
        Object value = body.get("enabled");
        if (!(value instanceof Boolean)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "enabled must be boolean");
        }
        return Map.of("enabled", state.set((Boolean) value));
    }

    @GetMapping("/probe")
    ResponseEntity<Map<String, Object>> probe() {
        if (state.enabled()) {
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body(Map.of("fault", "E5_ORDER_HTTP_500", "message", "E5 probe fault enabled"));
        }
        return ResponseEntity.ok(Map.of("fault", false, "message", "E5 probe healthy"));
    }
}
