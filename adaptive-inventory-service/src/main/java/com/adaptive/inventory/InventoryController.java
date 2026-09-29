package com.adaptive.inventory;

import jakarta.validation.Valid;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.util.List;

@RestController
@RequestMapping("/api/inventory")
class InventoryController {

    private final InventoryService service;

    InventoryController(InventoryService service) {
        this.service = service;
    }

    @PostMapping
    ResponseEntity<InventoryItem> create(@Valid @RequestBody InventoryCreateRequest request) {
        InventoryItem item = service.create(request);
        return ResponseEntity.created(URI.create("/api/inventory/" + item.getProductId())).body(item);
    }

    @GetMapping
    List<InventoryItem> findAll() {
        return service.findAll();
    }

    @GetMapping("/{productId}")
    InventoryItem findByProductId(@PathVariable Long productId) {
        return service.findByProductId(productId);
    }

    @PutMapping("/{productId}")
    InventoryItem update(@PathVariable Long productId, @Valid @RequestBody InventoryUpdateRequest request) {
        return service.update(productId, request);
    }

    @DeleteMapping("/{productId}")
    ResponseEntity<Void> delete(@PathVariable Long productId) {
        service.delete(productId);
        return ResponseEntity.noContent().build();
    }
}
