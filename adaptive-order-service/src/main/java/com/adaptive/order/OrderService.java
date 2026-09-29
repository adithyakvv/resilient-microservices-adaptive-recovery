package com.adaptive.order;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
class OrderService {

    private final OrderRepository repository;
    private final DependencyGateway dependencies;

    OrderService(OrderRepository repository, DependencyGateway dependencies) {
        this.repository = repository;
        this.dependencies = dependencies;
    }

    @Transactional
    OrderResponse create(OrderRequest request) {
        dependencies.validateOrder(request.productId(), request.quantity());
        return OrderResponse.from(repository.save(new CustomerOrder(request.productId(), request.quantity())));
    }

    @Transactional(readOnly = true)
    List<OrderResponse> findAll() {
        return repository.findAll().stream().map(OrderResponse::from).toList();
    }

    @Transactional(readOnly = true)
    OrderResponse findById(Long id) {
        return OrderResponse.from(requiredOrder(id));
    }

    @Transactional
    OrderResponse update(Long id, OrderRequest request) {
        CustomerOrder order = requiredOrder(id);
        dependencies.validateOrder(request.productId(), request.quantity());
        order.update(request.productId(), request.quantity());
        return OrderResponse.from(order);
    }

    @Transactional
    void delete(Long id) {
        repository.delete(requiredOrder(id));
    }

    private CustomerOrder requiredOrder(Long id) {
        return repository.findById(id)
                .orElseThrow(() -> new NotFoundException("Order not found: " + id));
    }
}
