#ifndef EMBEDDED_SIM_CHECKSUM_H
#define EMBEDDED_SIM_CHECKSUM_H

#include <stddef.h>
#include <stdint.h>

/* Fletcher-16 checksum over a byte buffer, as commonly used to validate a
 * firmware/sensor-frame payload before acting on it. Deterministic and
 * dependency-free so it can be cross-compiled for an embedded target with
 * no libc surprises. */
uint16_t fletcher16(const uint8_t *data, size_t len);

#endif /* EMBEDDED_SIM_CHECKSUM_H */
