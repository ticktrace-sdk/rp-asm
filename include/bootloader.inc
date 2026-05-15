@ =============================================================================
@ bootloader.inc - Constants shared by SSBL, TSBL flavors, and the apps they
@                  load. Mirrored byte-for-byte by tools/internal/manifest in
@                  the Go tooling.
@
@ Stage chain on RP2350:
@
@   FSBL (mask-ROM bootrom)
@     |  Loads SSBL via UF2 / IMAGE_DEF; SP/PC from vec[0]/vec[1] at slot base.
@     v
@   SSBL  at 0x10000000  (this SDK ships one; rarely re-flashed)
@     |  Validates TSBL footer, computes CRC32 over TSBL payload, jumps.
@     v
@   TSBL  at 0x10001000  (flavored: bypass / ab / dfu / signed; field-updatable)
@     |  Validates app footer, computes CRC32 over app payload, jumps.
@     v
@   App   at 0x10008000  (and 0x10080000 for slot B in -ab flavors)
@
@ Each stage is self-contained: the footer at the END of each slot carries
@ the size + CRC32 that the previous stage uses to validate the next, so a
@ field update of TSBL or an app does not require also rewriting state held
@ somewhere else. Phase 2 (-ab) adds a separate state sector at 0x10007000
@ for slot-selection bookkeeping; Phase 1 (-bypass) does not need it.
@ =============================================================================

@ ---- Memory map (Phase 1, single-slot -bypass flavor) ----------------------

    .equ BL_SSBL_BASE,            0x10000000
    .equ BL_SSBL_SIZE,            0x00001000    @ 4 KiB
    .equ BL_SSBL_FOOTER,          0x10000F00    @ SSBL footer (last 256 B)
    .equ BL_SSBL_SERVICES_OFFSET, 0x00000E00    @ rodata services table within SSBL

    .equ BL_TSBL_BASE,            0x10001000
    .equ BL_TSBL_SIZE,            0x00006000    @ 24 KiB
    .equ BL_TSBL_FOOTER,          0x10006F00    @ TSBL footer (last 256 B of slot)

    .equ BL_STATE_BASE,           0x10007000
    .equ BL_STATE_SIZE,           0x00001000    @ 4 KiB, reserved in Phase 1

    .equ BL_APP_SLOT_A_BASE,      0x10008000
    .equ BL_APP_SLOT_A_SIZE,      0x00078000    @ 480 KiB
    .equ BL_APP_SLOT_A_FOOTER,    0x1007FF00    @ last 256 B of slot

    @ Slot B is defined here for future -ab flavors; -bypass does not use it.
    .equ BL_APP_SLOT_B_BASE,      0x10080000
    .equ BL_APP_SLOT_B_SIZE,      0x00078000
    .equ BL_APP_SLOT_B_FOOTER,    0x100F7F00

@ ---- Slot-footer layout (256 bytes) ----------------------------------------
@
@   +0x00  magic        "RPBL"  little-endian -> 0x4C425052
@   +0x04  format_ver   u32     starts at 1
@   +0x08  payload_size u32     bytes of payload covered by crc32 / digest
@   +0x0C  crc32        u32     IEEE 802.3 over payload[0 .. payload_size)
@   +0x10  digest_sha256 32 B   SHA-256 over the same range (Phase 1: optional,
@                                may be all-zero; -signed flavors require it)
@   +0x30  signature   64 B     ed25519 over (magic .. digest); zero if unsigned
@   +0x70  seq         u32      monotonic counter for -ab slot selection
@   +0x74  status      u32      enum below
@   +0x78  flavor_min  u32      minimum TSBL flavor required (bitmap)
@   +0x7C  reserved    132 B    pad to 256 B; future use
@
@ The footer lives at SLOT_BASE + (SLOT_SIZE - 256). The payload range is
@ [SLOT_BASE, SLOT_BASE + payload_size). The footer itself is NOT part of
@ the CRC'd range.

    .equ BL_FOOTER_SIZE,           256
    .equ BL_FOOTER_MAGIC,          0x4C425052    @ "RPBL"
    .equ BL_FOOTER_FORMAT_VERSION, 1

    .equ BL_FOOTER_OFF_MAGIC,       0x00
    .equ BL_FOOTER_OFF_FORMAT_VER,  0x04
    .equ BL_FOOTER_OFF_PAYLOAD_SZ,  0x08
    .equ BL_FOOTER_OFF_CRC32,       0x0C
    .equ BL_FOOTER_OFF_DIGEST,      0x10
    .equ BL_FOOTER_OFF_SIGNATURE,   0x30
    .equ BL_FOOTER_OFF_SEQ,         0x70
    .equ BL_FOOTER_OFF_STATUS,      0x74
    .equ BL_FOOTER_OFF_FLAVOR_MIN,  0x78

@ ---- Footer status enum (bit-clear transitions, no erase needed) -----------

    .equ BL_STATUS_EMPTY,    0xFFFFFFFF    @ erased flash
    .equ BL_STATUS_STAGED,   0xFFFFFFFE    @ image written, not yet booted
    .equ BL_STATUS_TRYING,   0xFFFFFFFC    @ booted once, awaiting confirm
    .equ BL_STATUS_GOOD,     0xFFFFFFF8    @ confirmed
    .equ BL_STATUS_BAD,      0x00000000    @ failed; do not boot

@ ---- Watchdog scratch ABI for bootloader sticky flags ----------------------
@
@ Picks up where Van Hunter Adams' RP2040 design left off: the app or the
@ TSBL writes a magic into WATCHDOG_SCRATCH[7] and triggers a watchdog
@ reset; the scratch register survives the warm reset, and the SSBL/TSBL
@ checks it on the way up.

    .equ BL_SCRATCH_REG,            7
    .equ BL_SCRATCH_NONE,           0x00000000
    .equ BL_SCRATCH_FORCE_DFU,      0xB001DF00    @ stay in DFU on next boot
    .equ BL_SCRATCH_FORCE_BOOTSEL,  0xB001B005    @ punt to mask-ROM BOOTSEL
    .equ BL_SCRATCH_PREFER_SLOT_A,  0xB001A2A0    @ -ab: boot A this time
    .equ BL_SCRATCH_PREFER_SLOT_B,  0xB001A2B0    @ -ab: boot B this time
