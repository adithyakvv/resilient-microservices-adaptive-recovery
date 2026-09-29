package com.adaptive.order;

import org.springframework.data.jpa.repository.JpaRepository;

interface OrderRepository extends JpaRepository<CustomerOrder, Long> {
}
