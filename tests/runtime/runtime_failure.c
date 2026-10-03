#include "dpp/runtime.h"

#include <string.h>

int main(int argc, char **argv) {
    if (dpp_rt_initialize() != 0 || argc != 2) {
        return 2;
    }

    if (strcmp(argv[1], "double-free") == 0) {
        void *address = dpp_rt_allocate(8, 0);
        if (address == NULL) {
            return 3;
        }
        dpp_rt_deallocate(address);
        dpp_rt_deallocate(address);
        return 4;
    }
    if (strcmp(argv[1], "invalid-free") == 0) {
        int stack_value = 0;
        dpp_rt_deallocate(&stack_value);
        return 5;
    }
    return 6;
}
