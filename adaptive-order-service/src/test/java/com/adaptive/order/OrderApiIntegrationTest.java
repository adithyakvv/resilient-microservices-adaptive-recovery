package com.adaptive.order;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Testcontainers
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class OrderApiIntegrationTest {

    @Container
    @ServiceConnection
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:17-alpine");

    private static final StubDependency PRODUCT = StubDependency.product();
    private static final StubDependency INVENTORY = StubDependency.inventory();

    @DynamicPropertySource
    static void dependencyUrls(DynamicPropertyRegistry registry) {
        registry.add("dependencies.product-base-url", PRODUCT::baseUrl);
        registry.add("dependencies.inventory-base-url", INVENTORY::baseUrl);
    }

    @LocalServerPort
    int port;

    @Autowired
    OrderRepository repository;

    private RestClient client;

    @BeforeEach
    void setUp() {
        repository.deleteAll();
        PRODUCT.reset();
        INVENTORY.reset();
        client = RestClient.create("http://localhost:" + port);
    }

    @AfterAll
    static void stopDependencies() {
        PRODUCT.stop();
        INVENTORY.stop();
    }

    @Test
    void createReadUpdateDeleteWhenDependenciesAreValid() {
        OrderResponse created = createOrder(10L, 2);
        assertThat(created.id()).isNotNull();
        assertThat(created.productId()).isEqualTo(10L);
        assertThat(created.quantity()).isEqualTo(2);
        assertThat(created.status()).isEqualTo("ACCEPTED");

        OrderResponse found = client.get()
                .uri("/api/orders/{id}", created.id())
                .retrieve()
                .body(OrderResponse.class);
        assertThat(found.id()).isEqualTo(created.id());
        assertThat(found.productId()).isEqualTo(created.productId());
        assertThat(found.quantity()).isEqualTo(created.quantity());
        assertThat(found.status()).isEqualTo(created.status());
        assertThat(found.createdAt()).isNotNull();

        OrderResponse updated = client.put()
                .uri("/api/orders/{id}", created.id())
                .contentType(MediaType.APPLICATION_JSON)
                .body(new OrderRequest(10L, 4))
                .retrieve()
                .body(OrderResponse.class);
        assertThat(updated.quantity()).isEqualTo(4);

        List<?> orders = client.get().uri("/api/orders").retrieve().body(List.class);
        assertThat(orders).hasSize(1);

        Map<?, ?> health = client.get().uri("/actuator/health").retrieve().body(Map.class);
        assertThat(health.get("status")).isEqualTo("UP");

        client.delete().uri("/api/orders/{id}", created.id()).retrieve().toBodilessEntity();
        assertThat(repository.count()).isZero();
        assertThatThrownBy(() -> client.get()
                .uri("/api/orders/{id}", created.id())
                .retrieve()
                .toBodilessEntity())
                .isInstanceOf(RestClientResponseException.class)
                .satisfies(exception -> assertThat(((RestClientResponseException) exception).getStatusCode().value())
                        .isEqualTo(404));
    }

    @Test
    void rejectsMissingProductClearly() {
        assertOrderRejected(999L, 1, 422, "Product does not exist");
        assertThat(repository.count()).isZero();
    }

    @Test
    void rejectsInactiveProductClearly() {
        PRODUCT.productActive = false;
        assertOrderRejected(10L, 1, 422, "Product is inactive");
        assertThat(repository.count()).isZero();
    }

    @Test
    void rejectsInsufficientStockClearly() {
        INVENTORY.inventoryQuantity = 1;
        assertOrderRejected(10L, 2, 409, "Insufficient stock");
        assertThat(repository.count()).isZero();
    }

    @Test
    void rejectsUnavailableProductDependencyClearly() {
        PRODUCT.available = false;
        assertOrderRejected(10L, 1, 503, "Product service is unavailable");
        assertThat(repository.count()).isZero();
    }

    @Test
    void rejectsUnavailableInventoryDependencyClearly() {
        INVENTORY.available = false;
        assertOrderRejected(10L, 1, 503, "Inventory service is unavailable");
        assertThat(repository.count()).isZero();
    }

    @Test
    void dependencyHealthReportsSuccessAndFailure() {
        Map<?, ?> healthy = client.get().uri("/api/dependencies").retrieve().body(Map.class);
        assertThat(healthy.get("status")).isEqualTo("UP");

        INVENTORY.available = false;
        assertThatThrownBy(() -> client.get().uri("/api/dependencies").retrieve().toBodilessEntity())
                .isInstanceOf(RestClientResponseException.class)
                .satisfies(exception -> {
                    RestClientResponseException response = (RestClientResponseException) exception;
                    assertThat(response.getStatusCode().value()).isEqualTo(503);
                    assertThat(response.getResponseBodyAsString()).contains("DOWN", "inventory");
                });
    }

    private OrderResponse createOrder(Long productId, int quantity) {
        return client.post()
                .uri("/api/orders")
                .contentType(MediaType.APPLICATION_JSON)
                .body(new OrderRequest(productId, quantity))
                .retrieve()
                .body(OrderResponse.class);
    }

    private void assertOrderRejected(Long productId, int quantity, int status, String message) {
        assertThatThrownBy(() -> createOrder(productId, quantity))
                .isInstanceOf(RestClientResponseException.class)
                .satisfies(exception -> {
                    RestClientResponseException response = (RestClientResponseException) exception;
                    assertThat(response.getStatusCode().value()).isEqualTo(status);
                    assertThat(response.getResponseBodyAsString()).contains(message);
                });
    }

    private static final class StubDependency {

        private final HttpServer server;
        private final Type type;
        private volatile boolean available = true;
        private volatile boolean productActive = true;
        private volatile int inventoryQuantity = 10;

        private StubDependency(Type type) {
            this.type = type;
            try {
                this.server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
                this.server.createContext("/", this::handle);
                this.server.start();
            } catch (IOException exception) {
                throw new IllegalStateException("Could not start dependency test server", exception);
            }
        }

        static StubDependency product() {
            return new StubDependency(Type.PRODUCT);
        }

        static StubDependency inventory() {
            return new StubDependency(Type.INVENTORY);
        }

        String baseUrl() {
            return "http://127.0.0.1:" + server.getAddress().getPort();
        }

        void reset() {
            available = true;
            productActive = true;
            inventoryQuantity = 10;
        }

        void stop() {
            server.stop(0);
        }

        private void handle(HttpExchange exchange) throws IOException {
            if (!available) {
                send(exchange, 503, "{\"status\":\"DOWN\"}");
                return;
            }

            String path = exchange.getRequestURI().getPath();
            if ("/actuator/health".equals(path)) {
                send(exchange, 200, "{\"status\":\"UP\"}");
                return;
            }

            if (type == Type.PRODUCT && "/api/products/10".equals(path)) {
                send(exchange, 200,
                        "{\"id\":10,\"sku\":\"SKU-10\",\"name\":\"Test product\",\"price\":12.50,\"active\":"
                                + productActive + "}");
                return;
            }

            if (type == Type.INVENTORY && "/api/inventory/10".equals(path)) {
                send(exchange, 200,
                        "{\"productId\":10,\"quantity\":" + inventoryQuantity + "}");
                return;
            }

            send(exchange, 404, "{\"message\":\"not found\"}");
        }

        private void send(HttpExchange exchange, int status, String body) throws IOException {
            byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            exchange.getResponseBody().write(bytes);
            exchange.close();
        }

        private enum Type {
            PRODUCT,
            INVENTORY
        }
    }
}
