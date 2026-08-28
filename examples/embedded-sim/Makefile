# examples/embedded-sim — Milestone M6 (Embedded Simulation Workspace).
#
# `configure`/`build`/`test` operate on a native host build (used to run the
# unit tests). `simulate` configures/builds a *separate* cross-compiled
# aarch64 build directory and runs the resulting firmware binary under
# `qemu-aarch64` (qemu-user): compile → run → check exit code/stdout. This
# is userspace/syscall emulation only — no MMIO/interrupts/boot process; see
# README.md.

HOST_BUILD_DIR   := build
TARGET_BUILD_DIR := build-target
TOOLCHAIN_FILE   := cmake/aarch64-toolchain.cmake

.PHONY: configure build test simulate clean

configure:
	cmake -S . -B $(HOST_BUILD_DIR) -G Ninja

build: configure
	cmake --build $(HOST_BUILD_DIR)

test: build
	ctest --test-dir $(HOST_BUILD_DIR) --output-on-failure

simulate:
	cmake -S . -B $(TARGET_BUILD_DIR) -G Ninja -DCMAKE_TOOLCHAIN_FILE=$(TOOLCHAIN_FILE)
	cmake --build $(TARGET_BUILD_DIR)
	qemu-aarch64 -L /usr/aarch64-linux-gnu $(TARGET_BUILD_DIR)/firmware

clean:
	rm -rf $(HOST_BUILD_DIR) $(TARGET_BUILD_DIR)
