package com.adaptive.inventory;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.http.MediaType;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Testcontainers
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class InventoryApiIntegrationTest {

    @Container
    @ServiceConnection
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:17-alpine");

    @LocalServerPort
    int port;

    @Autowired
    InventoryRepository repository;

    private RestClient client;

    @BeforeEach
    void setUp() {
        repository.deleteAll();
        client = RestClient.create("http://localhost:" + port);
    }

    @Test
    void createReadUpdateDeleteAndHealthWork() {
        InventoryItem created = client.post()
                .uri("/api/inventory")
                .contentType(MediaType.APPLICATION_JSON)
                .body(new InventoryCreateRequest(101L, 12))
                .retrieve()
                .body(InventoryItem.class);

        assertThat(created).isNotNull();
        assertThat(created.getProductId()).isEqualTo(101L);
        assertThat(created.getQuantity()).isEqualTo(12);

        InventoryItem found = client.get()
                .uri("/api/inventory/{productId}", 101L)
                .retrieve()
                .body(InventoryItem.class);
        assertThat(found.getQuantity()).isEqualTo(12);

        InventoryItem updated = client.put()
                .uri("/api/inventory/{productId}", 101L)
                .contentType(MediaType.APPLICATION_JSON)
                .body(new InventoryUpdateRequest(25))
                .retrieve()
                .body(InventoryItem.class);
        assertThat(updated.getQuantity()).isEqualTo(25);

        List<?> inventory = client.get().uri("/api/inventory").retrieve().body(List.class);
        assertThat(inventory).hasSize(1);

        Map<?, ?> health = client.get().uri("/actuator/health").retrieve().body(Map.class);
        assertThat(health.get("status")).isEqualTo("UP");

        client.delete().uri("/api/inventory/{productId}", 101L).retrieve().toBodilessEntity();
        assertThat(repository.count()).isZero();
        assertThatThrownBy(() -> client.get()
                .uri("/api/inventory/{productId}", 101L)
                .retrieve()
                .toBodilessEntity())
                .isInstanceOf(RestClientResponseException.class)
                .satisfies(exception -> assertThat(((RestClientResponseException) exception).getStatusCode().value())
                        .isEqualTo(404));
    }
}
