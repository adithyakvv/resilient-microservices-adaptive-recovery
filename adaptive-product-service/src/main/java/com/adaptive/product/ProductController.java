package com.adaptive.product;

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
@RequestMapping("/api/products")
class ProductController {

    private final ProductService service;

    ProductController(ProductService service) {
        this.service = service;
    }

    @PostMapping
    ResponseEntity<Product> create(@Valid @RequestBody ProductRequest request) {
        Product product = service.create(request);
        return ResponseEntity.created(URI.create("/api/products/" + product.getId())).body(product);
    }

    @GetMapping
    List<Product> findAll() {
        return service.findAll();
    }

    @GetMapping("/{id}")
    Product findById(@PathVariable Long id) {
        return service.findById(id);
    }

    @PutMapping("/{id}")
    Product update(@PathVariable Long id, @Valid @RequestBody ProductRequest request) {
        return service.update(id, request);
    }

    @DeleteMapping("/{id}")
    ResponseEntity<Void> delete(@PathVariable Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }
}
