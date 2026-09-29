package com.adaptive.inventory;

import jakarta.validation.constraints.PositiveOrZero;

public record InventoryUpdateRequest(@PositiveOrZero int quantity) {
}
