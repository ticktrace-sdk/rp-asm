// bench_sha256_64k (pico-sdk) — paired with rp-asm/bench_sha256_64k.S.
//
// Hash 64 KiB of 0xA5 via the RP2350 hardware SHA-256 engine.

#include <stdio.h>
#include <string.h>
#include "pico/stdlib.h"
#include "hardware/structs/dwt.h"
#include "hardware/structs/sha256.h"
#include "hardware/resets.h"
#include "hardware/clocks.h"

#define MSG_LEN 65536u

static const uint8_t payload[MSG_LEN] __attribute__((aligned(4))) = { [0 ... MSG_LEN-1] = 0xA5 };
static uint32_t digest[8];

static void dwt_init_local(void) {
    *((volatile uint32_t*)0xE000EDFC) |= (1u << 24);
    *((volatile uint32_t*)0xE0001FB0)  = 0xC5ACCE55;
    dwt_hw->cyccnt = 0;
    dwt_hw->ctrl  |= 1;
}

static void sha256_compute_local(const uint8_t *msg, size_t len, uint32_t *out) {
    unreset_block_wait(RESETS_RESET_SHA256_BITS);
    sha256_hw->csr = (2u << 3) | (1u << 6);  // DMA_SIZE=word | BSWAP
    sha256_hw->csr |= 1;  // START
    while (sha256_hw->csr & 1) {}

    // Push body in 64-byte blocks
    const uint32_t *w = (const uint32_t *)msg;
    size_t full_blocks = len / 64;
    for (size_t b = 0; b < full_blocks; b++) {
        for (int i = 0; i < 16; i++) {
            while (!(sha256_hw->csr & (1u << 1))) {}
            sha256_hw->wdata = *w++;
        }
    }

    // Padded tail (we know len is a multiple of 64 here, so the final block
    // is just 0x80 | 55 zero bytes | 8-byte BE length)
    uint8_t tail[64] = {0};
    size_t rem = len % 64;
    memcpy(tail, msg + len - rem, rem);
    tail[rem] = 0x80;
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++) {
        tail[63 - i] = (bits >> (i * 8)) & 0xFF;
    }
    const uint32_t *tw = (const uint32_t *)tail;
    for (int i = 0; i < 16; i++) {
        while (!(sha256_hw->csr & (1u << 1))) {}
        sha256_hw->wdata = tw[i];
    }

    while (!(sha256_hw->csr & (1u << 2))) {}
    for (int i = 0; i < 8; i++) out[i] = sha256_hw->sum[i];
}

int main(void) {
    set_sys_clock_khz(150000, true);
    stdio_uart_init_full(uart0, 115200, 0, 1);
    dwt_init_local();

    printf("bench: sha256 64 KiB\r\n");

    uint32_t t0 = dwt_hw->cyccnt;
    sha256_compute_local(payload, MSG_LEN, digest);
    uint32_t cycles = dwt_hw->cyccnt - t0;

    printf("BENCH name=sha256_64k metric=cycles_total value=0x%08lx\r\n",
           (unsigned long)cycles);
    uint32_t mbps_x100 = 983040000u / cycles;
    printf("BENCH name=sha256_64k metric=mbps_x100 value=0x%08lx\r\n",
           (unsigned long)mbps_x100);

    for (;;) tight_loop_contents();
}
