# embedded-sim

Milestone M6 example: prove the `embedded-linux` Coder workspace can
compile, unit-test, and "simulate" a firmware-like artifact — without any
physical hardware.

```bash
make configure   # host build dir, for unit tests
make build       # builds test_checksum (and firmware, native) in build/
make test        # ctest: runs test_checksum
make simulate    # cross-compiles firmware for aarch64, runs it under qemu-user
```

## What "simulate" actually proves

`simulate` cross-compiles `firmware` for `aarch64-linux-gnu` and runs it
under `qemu-aarch64` (`qemu-user`, userspace emulation). This proves the
binary was built for a different target architecture and that its syscalls
(here: just `write`/`exit` via libc `printf`/`return`) execute correctly
under emulation — i.e. "compile → run → check exit code/stdout" for a
cross-compiled binary against the target's libc.

**Caveat:** `qemu-user` emulates userspace/syscalls only. There is no
MMIO, no interrupts, no peripherals, and no boot process — this is not a
hardware simulator. Real bare-metal firmware (no libc, direct memory-mapped
I/O, custom linker script/boot code) needs `qemu-system` with a machine
model instead (e.g. `qemu-system-arm -M <board>`), which is out of scope
for this example.

## The "firmware"

`firmware` computes a Fletcher-16 checksum over a fixed simulated sensor
frame and exits `0` only if it matches a known-good pinned value —
standing in for a firmware self-check on boot. `test_checksum` unit-tests
the checksum function itself (host build, run via `ctest`) with known
Fletcher-16 test vectors plus a corruption-detection regression check.
