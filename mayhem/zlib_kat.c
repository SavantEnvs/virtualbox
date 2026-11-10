/* Known-answer test for the vendored zlib (src/libs/zlib-1.3.2). Prints one `name=value` line per
 * check; mayhem/test.sh compares them with the expected values. Deliberately avoids the gzip *read*
 * functions: upstream's own test/example.c exercises them and aborts on the code under study. */
#include <stdio.h>
#include <string.h>

#include "zlib.h"

static void hex(const char *name, const unsigned char *p, unsigned long n)
{
    printf("%s=", name);
    for (unsigned long i = 0; i < n; i++)
        printf("%02x", p[i]);
    printf("\n");
}

int main(int argc, char **argv)
{
    static const char text[] = "hello, hello!";
    unsigned char comp[128], back[128];
    uLongf clen = sizeof(comp), blen = sizeof(back);

    printf("crc32=%08lx\n", (unsigned long)crc32(crc32(0L, Z_NULL, 0), (const Bytef *)"123456789", 9));
    printf("adler32=%08lx\n", (unsigned long)adler32(adler32(0L, Z_NULL, 0), (const Bytef *)"123456789", 9));

    if (compress2(comp, &clen, (const Bytef *)text, sizeof(text) - 1, 6) != Z_OK)
        return 1;
    hex("compress6", comp, clen);
    clen = sizeof(comp);
    if (compress2(comp, &clen, (const Bytef *)text, sizeof(text) - 1, 9) != Z_OK)
        return 1;
    hex("compress9", comp, clen);

    if (uncompress(back, &blen, comp, clen) != Z_OK)
        return 1;
    printf("uncompress=%.*s\n", (int)blen, back);

    static const unsigned char fixed[] = { 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0xc8,
                                           0x00, 0x51, 0x8a, 0x00, 0x21, 0x70, 0x04, 0x96 };
    blen = sizeof(back);
    if (uncompress(back, &blen, fixed, sizeof(fixed)) != Z_OK)
        return 1;
    printf("inflate_fixed=%.*s\n", (int)blen, back);

    /* a corrupted stream must be rejected */
    unsigned char bad[sizeof(fixed)];
    memcpy(bad, fixed, sizeof(bad));
    bad[sizeof(bad) - 1] ^= 0xff;
    blen = sizeof(back);
    printf("inflate_bad_adler=%d\n", uncompress(back, &blen, bad, sizeof(bad)));

    if (argc > 1) { /* write a gzip file: mayhem/test.sh decodes it with gzip(1) */
        gzFile gz = gzopen(argv[1], "wb");
        if (gz == NULL)
            return 1;
        gzputs(gz, "hello, ");
        gzprintf(gz, "%s!\n", "gz");
        if (gzclose(gz) != Z_OK)
            return 1;
    }
    printf("version=%s\n", zlibVersion());
    return 0;
}
