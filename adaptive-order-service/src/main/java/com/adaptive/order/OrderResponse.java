package com.adaptive.order;

import java.time.Instant;

public record OrderResponse(
        Long id,
        Long productId,
        int quantity,
        String status,
        Instant createdAt) {

    static OrderResponse from(CustomerOrder order) {
        return new OrderResponse(
                order.getId(),
                order.getProductId(),
                order.getQuantity(),
                order.getStatus().name(),
                order.getCreatedAt());
    }
}
