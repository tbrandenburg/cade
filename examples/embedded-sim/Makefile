# examples/embedded-sim — Milestone M6 (Embedded Simulation Workspace).
#
# `configure`/`build`/`test` operate on a native host build (used to run the
# unit tests). `simulate` configures/builds a *separate* cross-compiled
# aarch64 build directory and runs the resulting firmware binary under
# `qemu-aarch64` (qemu-user): compile → run → check exit code/stdout. This
# is userspace/syscall emulation only — no MMIO/interrupts/boot process; see
# README.md.
#
# Milestone M7: both build dirs pass -DCMAKE_C_COMPILER_LAUNCHER=sccache
# when `sccache` is on PATH (embedded-linux workspace image), falling back
# to a plain compile otherwise so this still builds without it.

HOST_BUILD_DIR   := build
TARGET_BUILD_DIR := build-target
TOOLCHAIN_FILE   := cmake/aarch64-toolchain.cmake

ifeq ($(shell command -v sccache 2>/dev/null),)
LAUNCHER_FLAG :=
else
LAUNCHER_FLAG := -DCMAKE_C_COMPILER_LAUNCHER=sccache
endif

.PHONY: configure build test simulate clean

configure:
	cmake -S . -B $(HOST_BUILD_DIR) -G Ninja $(LAUNCHER_FLAG)

build: configure
	cmake --build $(HOST_BUILD_DIR)

test: build
	ctest --test-dir $(HOST_BUILD_DIR) --output-on-failure

simulate:
	cmake -S . -B $(TARGET_BUILD_DIR) -G Ninja -DCMAKE_TOOLCHAIN_FILE=$(TOOLCHAIN_FILE) $(LAUNCHER_FLAG)
	cmake --build $(TARGET_BUILD_DIR)
	qemu-aarch64 -L /usr/aarch64-linux-gnu $(TARGET_BUILD_DIR)/firmware

clean:
	rm -rf $(HOST_BUILD_DIR) $(TARGET_BUILD_DIR)

