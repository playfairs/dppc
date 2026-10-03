#include "dpp/runtime.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

void dpp_rt_panic(const char *message, const char *file, uint32_t line) {
    if (file != NULL && file[0] != '\0') {
        fprintf(stderr, "dpp runtime panic at %s:%" PRIu32 ": %s\n", file, line,
                message != NULL ? message : "unspecified failure");
    } else {
        fprintf(stderr, "dpp runtime panic: %s\n",
                message != NULL ? message : "unspecified failure");
    }
    fflush(stderr);
    abort();
}
