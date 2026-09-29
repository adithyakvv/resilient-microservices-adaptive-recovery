package com.adaptive.inventory;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

@Entity
@Table(name = "inventory_items", schema = "inventory_service")
public class InventoryItem {

    @Id
    @Column(name = "product_id", nullable = false)
    private Long productId;

    @Column(nullable = false)
    private int quantity;

    protected InventoryItem() {
    }

    InventoryItem(Long productId, int quantity) {
        this.productId = productId;
        this.quantity = quantity;
    }

    void setQuantity(int quantity) {
        this.quantity = quantity;
    }

    public Long getProductId() {
        return productId;
    }

    public int getQuantity() {
        return quantity;
    }
}
