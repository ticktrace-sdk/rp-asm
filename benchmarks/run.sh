#!/usr/bin/env bash
# benchmarks/run.sh — flash a UF2 and capture BENCH lines from UART0.
#
# Usage:
#   benchmarks/run.sh <path/to/bench.uf2> <serial_device> [seconds=5]
#
# Requires picotool (to flash) and a serial reader (we use Python so we
# don't depend on picocom/screen).  Prints captured lines to stdout and
# returns 0 even on no-output so callers can aggregate.

set -u
uf2="$1"
serial="$2"
seconds="${3:-5}"

if [ ! -f "$uf2" ]; then
    echo "FAIL: $uf2 missing" >&2
    exit 1
fi

if ! command -v picotool >/dev/null 2>&1; then
    echo "SKIP: picotool not installed (see README.md, T4 needs it)" >&2
    exit 0
fi

echo "==> flashing $uf2"
picotool load -fx "$uf2" || {
    echo "FAIL: picotool load returned $?" >&2
    exit 2
}

echo "==> capturing $serial for ${seconds}s"
python3 - "$serial" "$seconds" <<'PYEOF'
import sys, time
try:
    import serial as pyserial
except ImportError:
    print("SKIP: pyserial not installed (pip install pyserial)", file=sys.stderr)
    sys.exit(0)

dev, secs = sys.argv[1], float(sys.argv[2])
with pyserial.Serial(dev, 115200, timeout=0.1) as s:
    end = time.time() + secs
    buf = b""
    while time.time() < end:
        chunk = s.read(256)
        if chunk:
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip().decode("utf-8", errors="replace")
                if line.startswith("BENCH "):
                    print(line)
PYEOF
