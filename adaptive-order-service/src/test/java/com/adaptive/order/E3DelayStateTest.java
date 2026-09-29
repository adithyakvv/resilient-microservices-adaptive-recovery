package com.adaptive.order;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class E3DelayStateTest {
    @Test
    void disabledByDefaultAndCanBeEnabledWithinBound() {
        E3DelayState state = new E3DelayState();
        assertThat(state.delayMs()).isZero();
        state.set(true, 1000);
        assertThat(state.delayMs()).isEqualTo(1000);
        state.set(false, 1000);
        assertThat(state.delayMs()).isZero();
    }

    @Test
    void rejectsUnsafeDelay() {
        E3DelayState state = new E3DelayState();
        assertThatThrownBy(() -> state.set(true, 1501)).isInstanceOf(IllegalArgumentException.class);
    }

}
