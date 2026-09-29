package com.adaptive.order;

class InvalidOrderException extends RuntimeException {

    InvalidOrderException(String message) {
        super(message);
    }
}
