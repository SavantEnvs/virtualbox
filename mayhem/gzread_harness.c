/* libFuzzer harness for the vendored zlib's gzip reader (src/libs/zlib-1.3.2): the input is the
 * content of a gzip (or plain) file, read through gzdopen/gzread/gzgets/gzclose_r. */
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "zlib.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    int fd = memfd_create("gzread", 0);
    if (fd < 0)
        return -1;

    size_t off = 0;
    while (off < size) {
        ssize_t n = write(fd, data + off, size - off);
        if (n <= 0) {
            close(fd);
            return -1;
        }
        off += (size_t)n;
    }
    if (lseek(fd, 0, SEEK_SET) != 0) {
        close(fd);
        return -1;
    }

    gzFile gz = gzdopen(fd, "rb");
    if (gz == NULL) {
        close(fd);
        return -1;
    }

    unsigned char buf[4096];
    int n;
    do
        n = gzread(gz, buf, sizeof(buf));
    while (n > 0);

    gzrewind(gz);
    char line[256];
    while (gzgets(gz, line, sizeof(line)) != NULL)
        ;
    (void)gzdirect(gz);

    gzclose_r(gz);
    return 0;
}
