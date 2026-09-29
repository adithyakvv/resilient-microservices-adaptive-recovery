package com.adaptive.order;

class StockConflictException extends RuntimeException {

    StockConflictException(String message) {
        super(message);
    }
}
