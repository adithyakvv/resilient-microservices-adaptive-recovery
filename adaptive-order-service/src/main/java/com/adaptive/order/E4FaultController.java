package com.adaptive.order;

import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Dedicated E4 probe and toggle; it never touches the order repository. */
@RestController
@RequestMapping("/api/internal/e4")
class E4FaultController {
    private final E4FaultState state;
    E4FaultController(E4FaultState state) { this.state = state; }

    @PostMapping("/fault")
    Map<String, Object> fault(@RequestBody Map<String, Object> body) {
        Object value = body.get("enabled");
        if (!(value instanceof Boolean)) {
            throw new org.springframework.web.server.ResponseStatusException(HttpStatus.BAD_REQUEST, "enabled must be boolean");
        }
        return Map.of("enabled", state.set((Boolean) value));
    }

    @GetMapping("/probe")
    ResponseEntity<Map<String, Object>> probe() {
        if (state.enabled()) {
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body(Map.of("fault", "E4_ORDER_HTTP_500", "message", "E4 probe fault enabled"));
        }
        return ResponseEntity.ok(Map.of("fault", false, "message", "E4 probe healthy"));
    }
}
