#include "dpp/runtime.h"

#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct allocator_counts {
    size_t allocations;
    size_t deallocations;
    int fail_next;
};

static void *tracked_allocate(size_t size, void *context) {
    struct allocator_counts *counts = context;
    counts->allocations++;
    if (counts->fail_next) {
        counts->fail_next = 0;
        return NULL;
    }
    return malloc(size);
}

static void tracked_deallocate(void *address, void *context) {
    struct allocator_counts *counts = context;
    counts->deallocations++;
    free(address);
}

int main(void) {
    assert(dpp_rt_is_initialized() == 0);
    assert(dpp_rt_allocate(8, 8) == NULL);
    assert(dpp_rt_initialize() == 0);
    assert(dpp_rt_initialize() == 0);
    assert(dpp_rt_is_initialized() == 1);
    assert(dpp_rt_set_allocator(NULL) == 0);

    void *aligned = dpp_rt_allocate(73, 64);
    assert(aligned != NULL);
    assert((uintptr_t)aligned % 64 == 0);
    assert(dpp_rt_live_allocation_count() == 1);
    assert(dpp_rt_live_allocated_bytes() == 73);
    dpp_rt_deallocate(aligned);
    assert(dpp_rt_live_allocation_count() == 0);
    assert(dpp_rt_live_allocated_bytes() == 0);

    uint8_t *zeroed = dpp_rt_allocate_zeroed(37, 256);
    assert(zeroed != NULL);
    assert((uintptr_t)zeroed % 256 == 0);
    for (size_t index = 0; index < 37; index++) {
        assert(zeroed[index] == 0);
    }
    memset(zeroed, 0x5a, 37);
    uint8_t *grown = dpp_rt_reallocate(zeroed, 91, 0);
    assert(grown != NULL);
    assert((uintptr_t)grown % 256 == 0);
    for (size_t index = 0; index < 37; index++) {
        assert(grown[index] == 0x5a);
    }
    assert(dpp_rt_live_allocation_count() == 1);
    assert(dpp_rt_live_allocated_bytes() == 91);
    assert(dpp_rt_reallocate(grown, SIZE_MAX, 0) == NULL);
    assert(dpp_rt_live_allocation_count() == 1);
    assert(dpp_rt_live_allocated_bytes() == 91);
    for (size_t index = 0; index < 37; index++) {
        assert(grown[index] == 0x5a);
    }
    uint8_t *shrunk = dpp_rt_reallocate(grown, 16, 0);
    assert(shrunk != NULL);
    assert((uintptr_t)shrunk % 256 == 0);
    for (size_t index = 0; index < 16; index++) {
        assert(shrunk[index] == 0x5a);
    }
    assert(dpp_rt_live_allocated_bytes() == 16);
    assert(dpp_rt_reallocate(shrunk, 0, 0) == NULL);
    assert(dpp_rt_live_allocation_count() == 0);
    assert(dpp_rt_live_allocated_bytes() == 0);

    void *empty = dpp_rt_allocate(0, 0);
    assert(empty != NULL);
    assert(dpp_rt_live_allocated_bytes() == 1);
    dpp_rt_deallocate(empty);
    assert(dpp_rt_allocate(8, 3) == NULL);
    assert(dpp_rt_allocate(SIZE_MAX, 8) == NULL);

    struct allocator_counts counts = {0};
    dpp_rt_allocator custom = {
        .allocate = tracked_allocate,
        .deallocate = tracked_deallocate,
        .context = &counts
    };
    assert(dpp_rt_set_allocator(&custom) == 0);
    counts.fail_next = 1;
    assert(dpp_rt_allocate(16, 16) == NULL);
    assert(dpp_rt_live_allocation_count() == 0);
    void *custom_memory = dpp_rt_allocate(16, 16);
    assert(custom_memory != NULL);
    assert(counts.allocations == 2);
    assert(dpp_rt_set_allocator(NULL) == -1);
    custom_memory = dpp_rt_reallocate(custom_memory, 32, 0);
    assert(custom_memory != NULL);
    assert(counts.allocations == 3);
    assert(counts.deallocations == 1);
    dpp_rt_deallocate(custom_memory);
    assert(counts.deallocations == 2);
    assert(dpp_rt_set_allocator(NULL) == 0);

    dpp_rt_finalize();
    assert(dpp_rt_is_initialized() == 0);
    assert(dpp_rt_allocate(8, 8) == NULL);
    assert(dpp_rt_initialize() == -1);
    return 0;
}
