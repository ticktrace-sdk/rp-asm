// bench_dma_memcpy (pico-sdk): paired with rp-asm/bench_dma_memcpy.S.
// DMA 16 KiB SRAM->SRAM, then CPU loop, report both.

#include <stdio.h>
#include "pico/stdlib.h"
#include "hardware/dma.h"
#include "hardware/structs/dwt.h"
#include "hardware/clocks.h"

#define BUF_BYTES 16384

static uint8_t src_buf[BUF_BYTES] __attribute__((aligned(4)));
static uint8_t dst_buf[BUF_BYTES] __attribute__((aligned(4)));

static void dwt_init_local(void) {
    *((volatile uint32_t*)0xE000EDFC) |= (1u << 24);
    *((volatile uint32_t*)0xE0001FB0)  = 0xC5ACCE55;
    dwt_hw->cyccnt = 0;
    dwt_hw->ctrl  |= 1;
}

int main(void) {
    set_sys_clock_khz(150000, true);
    stdio_uart_init_full(uart0, 115200, 0, 1);
    dwt_init_local();

    for (int i = 0; i < BUF_BYTES; i++) src_buf[i] = 0x5A;

    printf("bench: dma vs cpu 16 KiB copy\r\n");

    // DMA timing
    int ch = dma_claim_unused_channel(true);
    dma_channel_config c = dma_channel_get_default_config(ch);
    channel_config_set_transfer_data_size(&c, DMA_SIZE_32);
    channel_config_set_read_increment(&c, true);
    channel_config_set_write_increment(&c, true);

    uint32_t t0 = dwt_hw->cyccnt;
    dma_channel_configure(ch, &c, dst_buf, src_buf, BUF_BYTES / 4, true);
    dma_channel_wait_for_finish_blocking(ch);
    uint32_t dma_cycles = dwt_hw->cyccnt - t0;

    printf("BENCH name=dma_memcpy_16k metric=dma_cycles value=0x%08lx\r\n",
           (unsigned long)dma_cycles);

    // CPU timing
    volatile uint32_t *s = (volatile uint32_t *)src_buf;
    volatile uint32_t *d = (volatile uint32_t *)dst_buf;
    t0 = dwt_hw->cyccnt;
    for (int i = 0; i < BUF_BYTES / 4; i++) d[i] = s[i];
    uint32_t cpu_cycles = dwt_hw->cyccnt - t0;

    printf("BENCH name=dma_memcpy_16k metric=cpu_cycles value=0x%08lx\r\n",
           (unsigned long)cpu_cycles);

    for (;;) tight_loop_contents();
}
