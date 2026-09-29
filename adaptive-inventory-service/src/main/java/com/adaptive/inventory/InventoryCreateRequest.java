package com.adaptive.inventory;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.PositiveOrZero;

public record InventoryCreateRequest(
        @NotNull @Positive Long productId,
        @PositiveOrZero int quantity) {
}
