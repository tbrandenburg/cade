#include <assert.h>
#include <stdint.h>
#include <stdio.h>

#include "checksum.h"

int main(void) {
    /* Known-answer test vector (RFC 1146-style Fletcher-16 example). */
    const uint8_t abcde[] = {'a', 'b', 'c', 'd', 'e'};
    assert(fletcher16(abcde, sizeof(abcde)) == 0xC8F0);

    /* Empty buffer must checksum to zero. */
    assert(fletcher16(abcde, 0) == 0x0000);

    /* A single corrupted byte must change the checksum (regression guard
     * against an implementation that ignores part of the input). */
    uint8_t corrupted[] = {'a', 'b', 'c', 'd', 'f'};
    assert(fletcher16(corrupted, sizeof(corrupted)) != fletcher16(abcde, sizeof(abcde)));

    printf("test_checksum: all assertions passed\n");
    return 0;
}
