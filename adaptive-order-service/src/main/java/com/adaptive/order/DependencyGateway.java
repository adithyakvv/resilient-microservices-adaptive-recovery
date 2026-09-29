package com.adaptive.order;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import org.springframework.web.client.ResourceAccessException;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;

import java.util.Objects;

@Component
class DependencyGateway {

    private final RestClient productClient;
    private final RestClient inventoryClient;
    private final MeterRegistry metrics;
    private final E3DelayState e3Delay;

    DependencyGateway(
            @Value("${dependencies.product-base-url}") String productBaseUrl,
            @Value("${dependencies.inventory-base-url}") String inventoryBaseUrl,
            MeterRegistry metrics,
            E3DelayState e3Delay) {
        this.productClient = client(productBaseUrl);
        this.inventoryClient = client(inventoryBaseUrl);
        this.metrics = metrics;
        this.e3Delay = e3Delay;
    }

    void validateOrder(Long productId, int requestedQuantity) {
        ProductSnapshot product = product(productId);
        if (!product.active()) {
            throw new InvalidOrderException("Product is inactive: " + productId);
        }

        InventorySnapshot inventory = inventory(productId);
        if (inventory.quantity() < requestedQuantity) {
            throw new StockConflictException(
                    "Insufficient stock for product %d: requested %d, available %d"
                            .formatted(productId, requestedQuantity, inventory.quantity()));
        }
    }

    DependencyReport health() {
        DependencyStatus product = health(productClient, "Product");
        DependencyStatus inventory = health(inventoryClient, "Inventory");
        String overall = product.up() && inventory.up() ? "UP" : "DOWN";
        return new DependencyReport(overall, product, inventory);
    }

    private ProductSnapshot product(Long productId) {
        try {
            ProductSnapshot response = productClient.get()
                    .uri("/api/products/{id}", productId)
                    .retrieve()
                    .body(ProductSnapshot.class);
            return Objects.requireNonNull(response, "Product service returned an empty response");
        } catch (RestClientResponseException exception) {
            if (exception.getStatusCode() == HttpStatus.NOT_FOUND) {
                throw new InvalidOrderException("Product does not exist: " + productId);
            }
            throw unavailable("Product", exception);
        } catch (ResourceAccessException | NullPointerException exception) {
            throw unavailable("Product", exception);
        }
    }

    private InventorySnapshot inventory(Long productId) {
        try {
            int delay = e3Delay.delayMs();
            if (delay > 0) {
                Thread.sleep(delay);
            }
            InventorySnapshot response = inventoryClient.get()
                    .uri("/api/inventory/{productId}", productId)
                    .retrieve()
                    .body(InventorySnapshot.class);
            return Objects.requireNonNull(response, "Inventory service returned an empty response");
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw unavailable("Inventory", exception);
        } catch (RestClientResponseException exception) {
            if (exception.getStatusCode() == HttpStatus.NOT_FOUND) {
                throw new InvalidOrderException("No inventory record exists for product: " + productId);
            }
            throw unavailable("Inventory", exception);
        } catch (ResourceAccessException | NullPointerException exception) {
            throw unavailable("Inventory", exception);
        }
    }

    private DependencyStatus health(RestClient client, String name) {
        Timer.Sample sample = Timer.start(metrics);
        try {
            HealthResponse response = client.get()
                    .uri("/actuator/health")
                    .retrieve()
                    .body(HealthResponse.class);
            boolean up = response != null && "UP".equalsIgnoreCase(response.status());
            recordProbe(name, up ? "up" : "down", sample);
            return new DependencyStatus(up ? "UP" : "DOWN", up ? "reachable" : "reported non-UP health");
        } catch (RuntimeException exception) {
            recordProbe(name, "down", sample);
            return new DependencyStatus("DOWN", name + " service unavailable");
        }
    }

    private void recordProbe(String dependency, String outcome, Timer.Sample sample) {
        metrics.counter("adaptive_order_dependency_probe_total", "dependency", dependency.toLowerCase(), "outcome", outcome).increment();
        sample.stop(metrics.timer("adaptive_order_dependency_probe_duration", "dependency", dependency.toLowerCase()));
    }

    private DependencyUnavailableException unavailable(String dependency, Exception cause) {
        return new DependencyUnavailableException(dependency + " service is unavailable", cause);
    }

    private RestClient client(String baseUrl) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(2_000);
        requestFactory.setReadTimeout(2_000);
        return RestClient.builder()
                .baseUrl(baseUrl)
                .requestFactory(requestFactory)
                .build();
    }

    private record ProductSnapshot(Long id, String sku, String name, java.math.BigDecimal price, boolean active) {
    }

    private record InventorySnapshot(Long productId, int quantity) {
    }

    private record HealthResponse(String status) {
    }

    record DependencyStatus(String status, String detail) {
        boolean up() {
            return "UP".equals(status);
        }
    }

    record DependencyReport(String status, DependencyStatus product, DependencyStatus inventory) {
        boolean up() {
            return "UP".equals(status);
        }
    }
}
