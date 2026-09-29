package com.adaptive.product;

import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
class ProductService {

    private final ProductRepository repository;

    ProductService(ProductRepository repository) {
        this.repository = repository;
    }

    @Transactional
    Product create(ProductRequest request) {
        if (repository.existsBySku(request.sku())) {
            throw new ConflictException("Product SKU already exists: " + request.sku());
        }
        try {
            return repository.save(new Product(request.sku(), request.name(), request.price(), request.active()));
        } catch (DataIntegrityViolationException exception) {
            throw new ConflictException("Product SKU already exists: " + request.sku());
        }
    }

    @Transactional(readOnly = true)
    List<Product> findAll() {
        return repository.findAll();
    }

    @Transactional(readOnly = true)
    Product findById(Long id) {
        return repository.findById(id)
                .orElseThrow(() -> new NotFoundException("Product not found: " + id));
    }

    @Transactional
    Product update(Long id, ProductRequest request) {
        Product product = findById(id);
        if (repository.existsBySkuAndIdNot(request.sku(), id)) {
            throw new ConflictException("Product SKU already exists: " + request.sku());
        }
        product.update(request);
        return product;
    }

    @Transactional
    void delete(Long id) {
        Product product = findById(id);
        repository.delete(product);
    }
}
