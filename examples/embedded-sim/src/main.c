#include <stdio.h>
#include <stdint.h>

#include "checksum.h"

/* Simulated sensor frame captured from an embedded peripheral: a small
 * fixed-size payload the "firmware" validates on boot before reporting
 * itself healthy. */
static const uint8_t sensor_frame[] = {
    0x02, 0x18, 0x00, 0x00, 0x7f, 0x2a, 0x91, 0x00,
    0x03, 0x18, 0x00, 0x01, 0x64, 0x2b, 0x8f, 0x00,
};

/* Known-good checksum for sensor_frame, computed once from fletcher16() and
 * pinned here so a corrupted frame (or a broken checksum implementation)
 * fails the firmware self-check instead of silently passing. */
#define EXPECTED_CHECKSUM 0xfa90

int main(void) {
    uint16_t checksum = fletcher16(sensor_frame, sizeof(sensor_frame));

    printf("embedded-sim firmware: sensor frame checksum = 0x%04x\n", checksum);

    if (checksum != EXPECTED_CHECKSUM) {
        fprintf(stderr, "embedded-sim firmware: FAIL (expected 0x%04x)\n", EXPECTED_CHECKSUM);
        return 1;
    }

    printf("embedded-sim firmware: self-check OK\n");
    return 0;
}
