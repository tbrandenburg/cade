cmake_minimum_required(VERSION 3.20)
project(embedded_sim C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The "firmware" artifact: cross-compiled to aarch64 when configured with
# cmake/aarch64-toolchain.cmake (the `simulate` Makefile target), native
# otherwise.
add_executable(firmware src/main.c src/checksum.c)

# Unit tests only make sense built and run for the host architecture — the
# `test` Makefile target only ever configures/builds this project without
# CMAKE_TOOLCHAIN_FILE, so this always targets the host here.
enable_testing()
add_executable(test_checksum tests/test_checksum.c src/checksum.c)
target_include_directories(test_checksum PRIVATE src)
add_test(NAME checksum_test COMMAND test_checksum)
