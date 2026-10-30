#include <stddef.h>
#include <stdint.h>

int provider_upstream_test_one_input(const uint8_t *buf, size_t len);

/* Upstream returns 1 on success and 0 on short input; libFuzzer only accepts 0 and -1 (reject). */
int FuzzerTestOneInput(const uint8_t *buf, size_t len)
{
    return provider_upstream_test_one_input(buf, len) ? 0 : -1;
}
