package com.adaptive.order;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/internal/e3-delay")
class E3DelayController {
    private final E3DelayState state;

    E3DelayController(E3DelayState state) {
        this.state = state;
    }

    @PostMapping
    ResponseEntity<?> set(@RequestBody DelayRequest request) {
        try {
            state.set(request.enabled(), request.delayMs());
            return ResponseEntity.ok(new DelayResponse(state.delayMs() > 0, state.delayMs()));
        } catch (IllegalArgumentException exception) {
            return ResponseEntity.badRequest().body(new ErrorResponse(exception.getMessage()));
        }
    }

    record DelayRequest(boolean enabled, int delayMs) {}
    record DelayResponse(boolean enabled, int delayMs) {}
    record ErrorResponse(String error) {}
}
