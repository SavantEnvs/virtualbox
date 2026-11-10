/* libFuzzer harness for the vendored zlib's gzip reader (src/libs/zlib-1.3.2).
 *
 * Input: one operation byte, then the content of a gzip (or plain) file that is read through
 * gzdopen + gzread/gzgets/gzdirect and closed. The operation byte picks which reads run and whether
 * the handle is released with gzclose_r() (bit 4) or abandoned with a plain close(fd), as a caller
 * that does not release the handle would; the other bits choose the reads. */
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "zlib.h"

#define OP_READ     0x01
#define OP_GETS     0x02
#define OP_REWIND   0x04
#define OP_DIRECT   0x08
#define OP_GZCLOSE  0x10

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 1)
        return 0;
    uint8_t ops = data[0];
    data++;
    size--;

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

    if (ops & OP_READ) {
        unsigned char buf[4096];
        int n;
        do
            n = gzread(gz, buf, sizeof(buf));
        while (n > 0);
    }
    if (ops & OP_REWIND)
        gzrewind(gz);
    if (ops & OP_GETS) {
        char line[256];
        while (gzgets(gz, line, sizeof(line)) != NULL)
            ;
    }
    if (ops & OP_DIRECT)
        (void)gzdirect(gz);

    if (ops & OP_GZCLOSE)
        gzclose_r(gz);
    else
        close(fd);
    return 0;
}
