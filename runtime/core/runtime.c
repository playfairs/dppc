#include "dpp/runtime.h"

#include <stdatomic.h>

enum runtime_state {
    RUNTIME_COLD,
    RUNTIME_INITIALIZING,
    RUNTIME_RUNNING,
    RUNTIME_FINALIZING,
    RUNTIME_FINALIZED
};

static _Atomic uint32_t state = RUNTIME_COLD;

int32_t dpp_rt_initialize(void) {
    for (;;) {
        uint32_t current = atomic_load_explicit(&state, memory_order_acquire);
        if (current == RUNTIME_RUNNING) {
            return 0;
        }
        if (current == RUNTIME_INITIALIZING) {
            continue;
        }
        if (current != RUNTIME_COLD) {
            return -1;
        }

        uint32_t expected = RUNTIME_COLD;
        if (atomic_compare_exchange_weak_explicit(&state, &expected, RUNTIME_INITIALIZING,
                memory_order_acq_rel, memory_order_acquire)) {
            atomic_store_explicit(&state, RUNTIME_RUNNING, memory_order_release);
            return 0;
        }
    }
}

void dpp_rt_finalize(void) {
    uint32_t expected = RUNTIME_RUNNING;
    if (atomic_compare_exchange_strong_explicit(&state, &expected, RUNTIME_FINALIZING,
            memory_order_acq_rel, memory_order_acquire)) {
        atomic_store_explicit(&state, RUNTIME_FINALIZED, memory_order_release);
    }
}

int32_t dpp_rt_is_initialized(void) {
    return atomic_load_explicit(&state, memory_order_acquire) == RUNTIME_RUNNING;
}
