cmake_minimum_required(VERSION 3.13)
include($ENV{PICO_SDK_PATH}/pico_sdk_init.cmake)

project(bench_minimum C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(bench_minimum main.c)

# Match rp-asm's "every cycle matters" intent: release with LTO + -Os for
# the smallest binary.  Drop -Os to -O3 for the throughput benches.
target_compile_options(bench_minimum PRIVATE -Os -flto)
target_link_options(bench_minimum PRIVATE -flto)

target_link_libraries(bench_minimum pico_stdlib)
pico_add_extra_outputs(bench_minimum)
