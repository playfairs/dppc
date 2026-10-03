#include "dpp/runtime.h"

#include <stdalign.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define DPP_RT_ALLOCATION_MAGIC UINT64_C(0x445050414c4c4f43)

struct allocation_header {
    uint64_t magic;
    size_t size;
    size_t alignment;
    void *allocation;
    void *user_address;
    dpp_rt_allocator allocator;
    struct allocation_header *next;
};

static atomic_flag allocator_lock = ATOMIC_FLAG_INIT;
static struct allocation_header *allocations;
static size_t live_allocations;
static size_t live_bytes;
static dpp_rt_allocator active_allocator;

static void lock_allocator(void) {
    while (atomic_flag_test_and_set_explicit(&allocator_lock, memory_order_acquire)) {
    }
}

static void unlock_allocator(void) {
    atomic_flag_clear_explicit(&allocator_lock, memory_order_release);
}

static void *system_allocate(size_t size, void *context) {
    (void)context;
    return malloc(size);
}

static void system_deallocate(void *address, void *context) {
    (void)context;
    free(address);
}

static dpp_rt_allocator default_allocator(void) {
    dpp_rt_allocator allocator = {
        .allocate = system_allocate,
        .deallocate = system_deallocate,
        .context = NULL
    };
    return allocator;
}

static int is_power_of_two(size_t value) {
    return value != 0 && (value & (value - 1)) == 0;
}

static size_t tracked_size(size_t size) {
    return size == 0 ? 1 : size;
}

static int allocation_size(size_t size, size_t alignment, size_t *total_size) {
    if (alignment < alignof(max_align_t)) {
        alignment = alignof(max_align_t);
    }
    if (alignment - 1 > SIZE_MAX - sizeof(struct allocation_header)) {
        return 0;
    }

    const size_t payload_size = size == 0 ? 1 : size;
    const size_t overhead = sizeof(struct allocation_header) + alignment - 1;
    if (payload_size > SIZE_MAX - overhead) {
        return 0;
    }
    *total_size = payload_size + overhead;
    return 1;
}

static void *allocate_with(size_t size, size_t alignment, int zeroed,
        const dpp_rt_allocator *allocator) {
    if (alignment < alignof(max_align_t)) {
        alignment = alignof(max_align_t);
    }
    size_t total_size;
    if (!allocation_size(size, alignment, &total_size)) {
        return NULL;
    }

    void *allocation = allocator->allocate(total_size, allocator->context);
    if (allocation == NULL) {
        return NULL;
    }

    const uintptr_t raw_address = (uintptr_t)allocation;
    if (raw_address % alignof(max_align_t) != 0) {
        allocator->deallocate(allocation, allocator->context);
        return NULL;
    }
    if (raw_address > UINTPTR_MAX - sizeof(struct allocation_header) - (alignment - 1)) {
        allocator->deallocate(allocation, allocator->context);
        return NULL;
    }
    const uintptr_t first_address = raw_address + sizeof(struct allocation_header);
    const uintptr_t aligned_address =
        (first_address + alignment - 1) & ~(uintptr_t)(alignment - 1);
    struct allocation_header *header =
        (struct allocation_header *)(aligned_address - sizeof(struct allocation_header));
    if ((uintptr_t)header % alignof(struct allocation_header) != 0) {
        allocator->deallocate(allocation, allocator->context);
        return NULL;
    }

    header->magic = DPP_RT_ALLOCATION_MAGIC;
    header->size = size == 0 ? 1 : size;
    header->alignment = alignment;
    header->allocation = allocation;
    header->user_address = (void *)aligned_address;
    header->allocator = *allocator;

    if (zeroed) {
        memset((void *)aligned_address, 0, header->size);
    }
    return (void *)aligned_address;
}

void *dpp_rt_allocate(size_t size, size_t alignment) {
    if (!dpp_rt_is_initialized()) {
        return NULL;
    }
    if (alignment == 0) {
        alignment = alignof(max_align_t);
    }
    if (!is_power_of_two(alignment)) {
        return NULL;
    }

    lock_allocator();
    if (live_allocations == SIZE_MAX || tracked_size(size) > SIZE_MAX - live_bytes) {
        unlock_allocator();
        return NULL;
    }
    dpp_rt_allocator allocator = active_allocator.allocate == NULL
        ? default_allocator() : active_allocator;
    void *address = allocate_with(size, alignment, 0, &allocator);
    if (address != NULL) {
        struct allocation_header *header =
            (struct allocation_header *)((uintptr_t)address - sizeof(struct allocation_header));
        header->next = allocations;
        allocations = header;
        live_allocations++;
        live_bytes += header->size;
    }
    unlock_allocator();
    return address;
}

void *dpp_rt_allocate_zeroed(size_t size, size_t alignment) {
    if (!dpp_rt_is_initialized()) {
        return NULL;
    }
    if (alignment == 0) {
        alignment = alignof(max_align_t);
    }
    if (!is_power_of_two(alignment)) {
        return NULL;
    }

    lock_allocator();
    if (live_allocations == SIZE_MAX || tracked_size(size) > SIZE_MAX - live_bytes) {
        unlock_allocator();
        return NULL;
    }
    dpp_rt_allocator allocator = active_allocator.allocate == NULL
        ? default_allocator() : active_allocator;
    void *address = allocate_with(size, alignment, 1, &allocator);
    if (address != NULL) {
        struct allocation_header *header =
            (struct allocation_header *)((uintptr_t)address - sizeof(struct allocation_header));
        header->next = allocations;
        allocations = header;
        live_allocations++;
        live_bytes += header->size;
    }
    unlock_allocator();
    return address;
}

static struct allocation_header **find_allocation(void *address) {
    struct allocation_header **link = &allocations;
    while (*link != NULL && (*link)->user_address != address) {
        link = &(*link)->next;
    }
    return link;
}

void dpp_rt_deallocate(void *address) {
    if (address == NULL) {
        return;
    }

    lock_allocator();
    struct allocation_header **link = find_allocation(address);
    if (*link == NULL || (*link)->magic != DPP_RT_ALLOCATION_MAGIC) {
        unlock_allocator();
        dpp_rt_panic("invalid or already-freed pointer passed to dpp_rt_deallocate", NULL, 0);
    }

    struct allocation_header *header = *link;
    *link = header->next;
    header->magic = 0;
    live_allocations--;
    live_bytes -= header->size;
    void *allocation = header->allocation;
    dpp_rt_allocator allocator = header->allocator;
    unlock_allocator();
    allocator.deallocate(allocation, allocator.context);
}

void *dpp_rt_reallocate(void *address, size_t new_size, size_t alignment) {
    if (address == NULL) {
        return dpp_rt_allocate(new_size, alignment);
    }
    if (new_size == 0) {
        dpp_rt_deallocate(address);
        return NULL;
    }

    lock_allocator();
    struct allocation_header **link = find_allocation(address);
    if (*link == NULL || (*link)->magic != DPP_RT_ALLOCATION_MAGIC) {
        unlock_allocator();
        dpp_rt_panic("invalid or already-freed pointer passed to dpp_rt_reallocate", NULL, 0);
    }
    size_t old_size = (*link)->size;
    if (alignment == 0) {
        alignment = (*link)->alignment;
    }
    unlock_allocator();

    void *replacement = dpp_rt_allocate(new_size, alignment);
    if (replacement == NULL) {
        return NULL;
    }
    memcpy(replacement, address, old_size < new_size ? old_size : new_size);
    dpp_rt_deallocate(address);
    return replacement;
}

int32_t dpp_rt_set_allocator(const dpp_rt_allocator *allocator) {
    if (!dpp_rt_is_initialized()) {
        return -1;
    }
    if (allocator != NULL && (allocator->allocate == NULL || allocator->deallocate == NULL)) {
        return -1;
    }

    lock_allocator();
    if (live_allocations != 0) {
        unlock_allocator();
        return -1;
    }
    active_allocator = allocator == NULL ? default_allocator() : *allocator;
    unlock_allocator();
    return 0;
}

size_t dpp_rt_live_allocation_count(void) {
    lock_allocator();
    size_t result = live_allocations;
    unlock_allocator();
    return result;
}

size_t dpp_rt_live_allocated_bytes(void) {
    lock_allocator();
    size_t result = live_bytes;
    unlock_allocator();
    return result;
}
