package com.adaptive.order;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

public record OrderRequest(
        @NotNull @Positive Long productId,
        @Positive int quantity) {
}
