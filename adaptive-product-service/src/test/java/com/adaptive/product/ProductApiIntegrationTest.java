package com.adaptive.product;

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

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Testcontainers
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class ProductApiIntegrationTest {

    @Container
    @ServiceConnection
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:17-alpine");

    @LocalServerPort
    int port;

    @Autowired
    ProductRepository repository;

    private RestClient client;

    @BeforeEach
    void setUp() {
        repository.deleteAll();
        client = RestClient.create("http://localhost:" + port);
    }

    @Test
    void createReadUpdateDeleteAndHealthWork() {
        Product created = client.post()
                .uri("/api/products")
                .contentType(MediaType.APPLICATION_JSON)
                .body(new ProductRequest("SKU-1", "Keyboard", new BigDecimal("49.95"), true))
                .retrieve()
                .body(Product.class);

        assertThat(created).isNotNull();
        assertThat(created.getId()).isNotNull();
        assertThat(created.getSku()).isEqualTo("SKU-1");

        Product found = client.get()
                .uri("/api/products/{id}", created.getId())
                .retrieve()
                .body(Product.class);
        assertThat(found.getName()).isEqualTo("Keyboard");

        Product updated = client.put()
                .uri("/api/products/{id}", created.getId())
                .contentType(MediaType.APPLICATION_JSON)
                .body(new ProductRequest("SKU-1", "Mechanical Keyboard", new BigDecimal("79.95"), true))
                .retrieve()
                .body(Product.class);
        assertThat(updated.getName()).isEqualTo("Mechanical Keyboard");
        assertThat(updated.getPrice()).isEqualByComparingTo("79.95");

        List<?> products = client.get().uri("/api/products").retrieve().body(List.class);
        assertThat(products).hasSize(1);

        Map<?, ?> health = client.get().uri("/actuator/health").retrieve().body(Map.class);
        assertThat(health.get("status")).isEqualTo("UP");

        client.delete().uri("/api/products/{id}", created.getId()).retrieve().toBodilessEntity();
        assertThat(repository.count()).isZero();
        assertThatThrownBy(() -> client.get()
                .uri("/api/products/{id}", created.getId())
                .retrieve()
                .toBodilessEntity())
                .isInstanceOf(RestClientResponseException.class)
                .satisfies(exception -> assertThat(((RestClientResponseException) exception).getStatusCode().value())
                        .isEqualTo(404));
    }
}
