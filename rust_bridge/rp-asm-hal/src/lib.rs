//! rp-asm-hal — embedded-hal 1.0 trait implementations on top of rp-asm.
//!
//! Thin wrappers over the asm drivers.  Every method is `unsafe extern "C"`
//! at the bottom; we put the `unsafe` blocks here so user code doesn't
//! have to.
//!
//! Constructors are documented as "the user is responsible for ensuring
//! the underlying peripheral has been initialised" — typically by
//! calling our asm `*_init` functions from the app's main before
//! constructing the wrapper.

#![no_std]
#![allow(clippy::missing_safety_doc)]

use core::convert::Infallible;
use core::fmt;

use embedded_hal::delay::DelayNs;
use embedded_hal::digital::{ErrorType as DigitalErrorType, InputPin, OutputPin, StatefulOutputPin};
use embedded_hal::i2c::{ErrorType as I2cErrorType, I2c, Operation, SevenBitAddress};
use embedded_hal::pwm::{ErrorType as PwmErrorType, SetDutyCycle};
use embedded_hal::spi::{ErrorType as SpiErrorType, SpiBus};

use rp_asm_sys as sys;

// ============================================================================
// Error type
// ============================================================================

/// Unified error type for rp-asm-hal.  The underlying asm drivers don't
/// expose detailed errors, so we keep this coarse.  Users who need
/// more detail can read peripheral status registers directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// Bus operation failed (NACK, arbitration loss, etc.)
    Bus,
    /// Invalid argument (pin out of range, etc.)
    InvalidArgument,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Bus => f.write_str("bus error"),
            Error::InvalidArgument => f.write_str("invalid argument"),
        }
    }
}

impl embedded_hal::digital::Error for Error {
    fn kind(&self) -> embedded_hal::digital::ErrorKind {
        embedded_hal::digital::ErrorKind::Other
    }
}

impl embedded_hal::i2c::Error for Error {
    fn kind(&self) -> embedded_hal::i2c::ErrorKind {
        match self {
            Error::Bus => embedded_hal::i2c::ErrorKind::Bus,
            Error::InvalidArgument => embedded_hal::i2c::ErrorKind::Other,
        }
    }
}

impl embedded_hal::spi::Error for Error {
    fn kind(&self) -> embedded_hal::spi::ErrorKind {
        embedded_hal::spi::ErrorKind::Other
    }
}

impl embedded_hal::pwm::Error for Error {
    fn kind(&self) -> embedded_hal::pwm::ErrorKind {
        embedded_hal::pwm::ErrorKind::Other
    }
}

impl embedded_io::Error for Error {
    fn kind(&self) -> embedded_io::ErrorKind {
        embedded_io::ErrorKind::Other
    }
}

// ============================================================================
// GPIO
// ============================================================================

/// A GPIO pin in SIO output / input mode.
///
/// Construct via `Pin::output(n)` or `Pin::input(n)`.  No bounds check
/// on `n`; the asm driver handles up to GPIO 47.
pub struct Pin {
    pin: u32,
    is_output: bool,
}

impl Pin {
    /// Configure pin `n` as a push-pull output, default low.
    pub fn output(n: u32) -> Self {
        unsafe {
            sys::gpio_init(n);
            sys::gpio_set_dir(n, 1);
        }
        Self { pin: n, is_output: true }
    }

    /// Configure pin `n` as an input.
    pub fn input(n: u32) -> Self {
        unsafe {
            sys::gpio_init(n);
            sys::gpio_set_dir(n, 0);
        }
        Self { pin: n, is_output: false }
    }

    /// Enable internal pull-up.
    pub fn pull_up(&mut self) -> &mut Self {
        unsafe { sys::gpio_pull_up(self.pin) };
        self
    }

    /// Enable internal pull-down.
    pub fn pull_down(&mut self) -> &mut Self {
        unsafe { sys::gpio_pull_down(self.pin) };
        self
    }

    /// The pin number this wraps.
    pub fn num(&self) -> u32 {
        self.pin
    }
}

impl DigitalErrorType for Pin {
    type Error = Infallible;
}

impl OutputPin for Pin {
    fn set_low(&mut self) -> Result<(), Self::Error> {
        unsafe { sys::gpio_put(self.pin, 0) };
        Ok(())
    }
    fn set_high(&mut self) -> Result<(), Self::Error> {
        unsafe { sys::gpio_put(self.pin, 1) };
        Ok(())
    }
}

impl StatefulOutputPin for Pin {
    fn is_set_high(&mut self) -> Result<bool, Self::Error> {
        // SIO_GPIO_OUT bit reads back the driven level.  Our asm doesn't
        // expose a direct getter for the "drive" state; gpio_get reads
        // the pad level, which is what set_high produces.  For an
        // open-drain pin this would differ; we don't expose OD here.
        Ok(unsafe { sys::gpio_get(self.pin) } != 0)
    }
    fn is_set_low(&mut self) -> Result<bool, Self::Error> {
        Ok(unsafe { sys::gpio_get(self.pin) } == 0)
    }
    fn toggle(&mut self) -> Result<(), Self::Error> {
        unsafe { sys::gpio_toggle(self.pin) };
        Ok(())
    }
}

impl InputPin for Pin {
    fn is_high(&mut self) -> Result<bool, Self::Error> {
        debug_assert!(!self.is_output, "Pin::input expected for InputPin");
        Ok(unsafe { sys::gpio_get(self.pin) } != 0)
    }
    fn is_low(&mut self) -> Result<bool, Self::Error> {
        Ok(unsafe { sys::gpio_get(self.pin) } == 0)
    }
}

// ============================================================================
// Delay (via DWT)
// ============================================================================

/// Cycle-accurate delay using DWT.CYCCNT.  Requires `dwt_init` to have
/// been called once at startup.
pub struct Delay {
    clk_sys_hz: u32,
}

impl Delay {
    /// Construct a Delay for the given clk_sys frequency.  Pass
    /// 150_000_000 for the M2 default.
    pub fn new(clk_sys_hz: u32) -> Self {
        Self { clk_sys_hz }
    }
}

impl DelayNs for Delay {
    fn delay_ns(&mut self, ns: u32) {
        // cycles = (ns * clk_mhz) / 1000 = ns * (clk_hz / 1_000_000_000)
        // For clk_sys = 150 MHz: cycles_per_ns = 0.15.  Below 7 ns the
        // call overhead dominates; we just return.
        let clk_mhz = self.clk_sys_hz / 1_000_000;
        let cycles = ((ns as u64) * (clk_mhz as u64) / 1000) as u32;
        if cycles < 4 {
            return;
        }
        let start = unsafe { sys::dwt_cycles_read() };
        while unsafe { sys::dwt_cycles_since(start) } < cycles {
            core::hint::spin_loop();
        }
    }
}

// ============================================================================
// I2C
// ============================================================================

/// I2C controller, idx 0 or 1.  User must call `sys::i2c_init(idx, hz)`
/// and `sys::i2c_set_pins(idx, sda, scl)` before constructing.
pub struct I2cBus {
    idx: u32,
}

impl I2cBus {
    pub unsafe fn from_idx(idx: u32) -> Self {
        Self { idx }
    }

    /// Convenience: bring the controller up and pin-mux SDA/SCL.
    pub fn new(idx: u32, baud: u32, sda: u32, scl: u32) -> Self {
        unsafe {
            // i2c_init currently lives in the asm core.
            extern "C" {
                fn i2c_init(idx: u32, baud: u32);
                fn i2c_set_pins(idx: u32, sda: u32, scl: u32);
            }
            i2c_init(idx, baud);
            i2c_set_pins(idx, sda, scl);
        }
        Self { idx }
    }
}

impl I2cErrorType for I2cBus {
    type Error = Error;
}

impl I2c<SevenBitAddress> for I2cBus {
    fn transaction(
        &mut self,
        address: SevenBitAddress,
        operations: &mut [Operation<'_>],
    ) -> Result<(), Self::Error> {
        // I2c::transaction semantics: between ops of the same direction,
        // no STOP+START (no restart).  Between ops of different
        // direction, restart.  STOP only after the final op.
        //
        // Our asm i2c_*_blocking takes a `nostop` flag.  Set it to 1 on
        // every op except the very last one.
        extern "C" {
            fn i2c_write_blocking(
                idx: u32,
                addr: u32,
                src: *const u8,
                len: u32,
                nostop: u32,
            ) -> i32;
            fn i2c_read_blocking(
                idx: u32,
                addr: u32,
                dst: *mut u8,
                len: u32,
                nostop: u32,
            ) -> i32;
        }

        let last = operations.len().saturating_sub(1);
        for (i, op) in operations.iter_mut().enumerate() {
            let nostop = if i == last { 0 } else { 1 };
            let result = unsafe {
                match op {
                    Operation::Write(buf) => i2c_write_blocking(
                        self.idx,
                        address as u32,
                        buf.as_ptr(),
                        buf.len() as u32,
                        nostop,
                    ),
                    Operation::Read(buf) => i2c_read_blocking(
                        self.idx,
                        address as u32,
                        buf.as_mut_ptr(),
                        buf.len() as u32,
                        nostop,
                    ),
                }
            };
            if result < 0 {
                return Err(Error::Bus);
            }
        }
        Ok(())
    }
}

// ============================================================================
// SPI bus
// ============================================================================

/// SPI bus on instance idx (0 or 1).  Caller-managed CS — use
/// `embedded-hal-bus::spi::ExclusiveDevice` to get `SpiDevice` over this
/// bus + a `Pin`.
pub struct Spi {
    idx: u32,
}

impl Spi {
    pub unsafe fn from_idx(idx: u32) -> Self {
        Self { idx }
    }

    /// Convenience: bring the controller up and pin-mux SCK/MOSI/MISO.
    /// CS is the user's problem; pass it as a `Pin` to `ExclusiveDevice`.
    pub fn new(idx: u32, baud: u32, sck: u32, mosi: u32, miso: u32) -> Self {
        unsafe {
            extern "C" {
                fn spi_init(idx: u32, baud: u32);
                fn spi_set_pins(idx: u32, sck: u32, mosi: u32, miso: u32, cs: u32);
            }
            spi_init(idx, baud);
            // CS = 0xFFFFFFFF means "no CS", handled in software.
            spi_set_pins(idx, sck, mosi, miso, u32::MAX);
        }
        Self { idx }
    }
}

impl SpiErrorType for Spi {
    type Error = Error;
}

impl SpiBus<u8> for Spi {
    fn read(&mut self, buf: &mut [u8]) -> Result<(), Self::Error> {
        extern "C" {
            fn spi_read_blocking(idx: u32, tx: u32, dst: *mut u8, n: u32);
        }
        unsafe { spi_read_blocking(self.idx, 0, buf.as_mut_ptr(), buf.len() as u32) };
        Ok(())
    }
    fn write(&mut self, buf: &[u8]) -> Result<(), Self::Error> {
        extern "C" {
            fn spi_write_blocking(idx: u32, src: *const u8, n: u32);
        }
        unsafe { spi_write_blocking(self.idx, buf.as_ptr(), buf.len() as u32) };
        Ok(())
    }
    fn transfer(&mut self, read: &mut [u8], write: &[u8]) -> Result<(), Self::Error> {
        extern "C" {
            fn spi_write_read_blocking(idx: u32, src: *const u8, dst: *mut u8, n: u32);
        }
        // PL022 transfer: same length for read + write
        let n = core::cmp::min(read.len(), write.len()) as u32;
        unsafe { spi_write_read_blocking(self.idx, write.as_ptr(), read.as_mut_ptr(), n) };
        Ok(())
    }
    fn transfer_in_place(&mut self, buf: &mut [u8]) -> Result<(), Self::Error> {
        extern "C" {
            fn spi_write_read_blocking(idx: u32, src: *const u8, dst: *mut u8, n: u32);
        }
        unsafe {
            spi_write_read_blocking(self.idx, buf.as_ptr(), buf.as_mut_ptr(), buf.len() as u32);
        }
        Ok(())
    }
    fn flush(&mut self) -> Result<(), Self::Error> {
        // PL022 flush would wait for !BUSY; our blocking ops already do
        // that implicitly between calls.  No-op here.
        Ok(())
    }
}

// ============================================================================
// UART (via embedded-io)
// ============================================================================

/// UART instance (0 or 1).  Implements `embedded_io::Read` + `Write`.
pub struct Uart {
    idx: u32,
}

impl Uart {
    pub unsafe fn from_idx(idx: u32) -> Self {
        Self { idx }
    }

    /// Convenience: initialise UART idx for given baud at clk_peri.
    pub fn new(idx: u32, baud: u32, clk_peri_hz: u32) -> Self {
        unsafe { sys::uart_init(idx, baud, clk_peri_hz) };
        Self { idx }
    }
}

impl embedded_io::ErrorType for Uart {
    type Error = Error;
}

impl embedded_io::Write for Uart {
    fn write(&mut self, buf: &[u8]) -> Result<usize, Self::Error> {
        for &b in buf {
            unsafe { sys::uart_putc_blocking(self.idx, b as u32) };
        }
        Ok(buf.len())
    }
    fn flush(&mut self) -> Result<(), Self::Error> {
        Ok(())
    }
}

impl embedded_io::Read for Uart {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, Self::Error> {
        for slot in buf.iter_mut() {
            *slot = unsafe { sys::uart_getc_blocking(self.idx) } as u8;
        }
        Ok(buf.len())
    }
}

impl core::fmt::Write for Uart {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for b in s.bytes() {
            unsafe { sys::uart_putc_blocking(self.idx, b as u32) };
        }
        Ok(())
    }
}

// ============================================================================
// PWM
// ============================================================================

/// A single PWM slice + channel.  The user is responsible for routing
/// the corresponding GPIO to PWM funcsel and for `pwm_init`.
pub struct PwmChannel {
    slice: u8,
    chan: u8,
    top: u16,
}

impl PwmChannel {
    pub unsafe fn from_parts(slice: u8, chan: u8, top: u16) -> Self {
        Self { slice, chan, top }
    }
}

impl PwmErrorType for PwmChannel {
    type Error = Infallible;
}

impl SetDutyCycle for PwmChannel {
    fn max_duty_cycle(&self) -> u16 {
        self.top
    }
    fn set_duty_cycle(&mut self, duty: u16) -> Result<(), Self::Error> {
        extern "C" {
            fn pwm_set_chan_level(slice: u32, chan: u32, level: u32);
        }
        unsafe { pwm_set_chan_level(self.slice as u32, self.chan as u32, duty as u32) };
        Ok(())
    }
}
