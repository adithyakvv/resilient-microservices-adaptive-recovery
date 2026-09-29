package com.adaptive.order;

class DependencyUnavailableException extends RuntimeException {

    DependencyUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
