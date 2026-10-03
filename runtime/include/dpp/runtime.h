#ifndef DPP_RUNTIME_H
#define DPP_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define DPP_RT_NORETURN __declspec(noreturn)
#else
#define DPP_RT_NORETURN __attribute__((noreturn))
#endif

#ifdef __cplusplus
extern "C" {
#endif

int32_t dpp_rt_initialize(void);
void dpp_rt_finalize(void);
int32_t dpp_rt_is_initialized(void);

typedef void *(*dpp_rt_allocate_fn)(size_t size, void *context);
typedef void (*dpp_rt_deallocate_fn)(void *address, void *context);

typedef struct dpp_rt_allocator {
    dpp_rt_allocate_fn allocate;
    dpp_rt_deallocate_fn deallocate;
    void *context;
} dpp_rt_allocator;

int32_t dpp_rt_set_allocator(const dpp_rt_allocator *allocator);
void *dpp_rt_allocate(size_t size, size_t alignment);
void *dpp_rt_allocate_zeroed(size_t size, size_t alignment);
void *dpp_rt_reallocate(void *address, size_t new_size, size_t alignment);
void dpp_rt_deallocate(void *address);
size_t dpp_rt_live_allocation_count(void);
size_t dpp_rt_live_allocated_bytes(void);

DPP_RT_NORETURN void dpp_rt_panic(const char *message, const char *file, uint32_t line);

#ifdef __cplusplus
}
#endif

#undef DPP_RT_NORETURN

#endif
