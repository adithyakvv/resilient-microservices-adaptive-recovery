package com.adaptive.inventory;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
class InventoryService {

    private final InventoryRepository repository;

    InventoryService(InventoryRepository repository) {
        this.repository = repository;
    }

    @Transactional
    InventoryItem create(InventoryCreateRequest request) {
        if (repository.existsById(request.productId())) {
            throw new ConflictException("Inventory already exists for product: " + request.productId());
        }
        return repository.save(new InventoryItem(request.productId(), request.quantity()));
    }

    @Transactional(readOnly = true)
    List<InventoryItem> findAll() {
        return repository.findAll();
    }

    @Transactional(readOnly = true)
    InventoryItem findByProductId(Long productId) {
        return repository.findById(productId)
                .orElseThrow(() -> new NotFoundException("Inventory not found for product: " + productId));
    }

    @Transactional
    InventoryItem update(Long productId, InventoryUpdateRequest request) {
        InventoryItem item = findByProductId(productId);
        item.setQuantity(request.quantity());
        return item;
    }

    @Transactional
    void delete(Long productId) {
        InventoryItem item = findByProductId(productId);
        repository.delete(item);
    }
}
