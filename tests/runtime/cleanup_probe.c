#include <stddef.h>

static int values[32];
static size_t count;

void dpp_test_cleanup_reset(void) {
    count = 0;
}

void dpp_test_cleanup_record(int value) {
    if (count < sizeof(values) / sizeof(values[0])) {
        values[count++] = value;
    }
}

int dpp_test_cleanup_count(void) {
    return (int)count;
}

int dpp_test_cleanup_value(int index) {
    if (index < 0 || (size_t)index >= count) {
        return -1;
    }
    return values[index];
}
