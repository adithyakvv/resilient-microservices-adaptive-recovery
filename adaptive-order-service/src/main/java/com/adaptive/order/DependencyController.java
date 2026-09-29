package com.adaptive.order;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/dependencies")
class DependencyController {

    private final DependencyGateway dependencies;

    DependencyController(DependencyGateway dependencies) {
        this.dependencies = dependencies;
    }

    @GetMapping
    ResponseEntity<DependencyGateway.DependencyReport> health() {
        DependencyGateway.DependencyReport report = dependencies.health();
        return ResponseEntity.status(report.up() ? HttpStatus.OK : HttpStatus.SERVICE_UNAVAILABLE).body(report);
    }
}
