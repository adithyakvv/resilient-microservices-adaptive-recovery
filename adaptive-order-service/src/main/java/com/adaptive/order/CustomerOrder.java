package com.adaptive.order;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;

@Entity
@Table(name = "customer_orders", schema = "order_service")
class CustomerOrder {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "product_id", nullable = false)
    private Long productId;

    @Column(nullable = false)
    private int quantity;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 32)
    private OrderStatus status;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    protected CustomerOrder() {
    }

    CustomerOrder(Long productId, int quantity) {
        this.productId = productId;
        this.quantity = quantity;
        this.status = OrderStatus.ACCEPTED;
        this.createdAt = Instant.now();
    }

    void update(Long productId, int quantity) {
        this.productId = productId;
        this.quantity = quantity;
        this.status = OrderStatus.ACCEPTED;
    }

    Long getId() {
        return id;
    }

    Long getProductId() {
        return productId;
    }

    int getQuantity() {
        return quantity;
    }

    OrderStatus getStatus() {
        return status;
    }

    Instant getCreatedAt() {
        return createdAt;
    }
}
