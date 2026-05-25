#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# ticktrace SDK container entrypoint.
#
# The image bakes a copy of the SDK source at /sdk. This script makes
# /workspace usable in three modes:
#
#   1. No mount at all          - /workspace starts empty, gets seeded from
#                                 /sdk, build runs inside the container.
#   2. Mount of an empty dir    - same as (1) but artefacts land on the host.
#   3. Mount of an SDK clone    - mount wins; build runs against the user's
#                                 source tree.
#
# If /workspace is non-empty but has no Makefile, refuse rather than risk
# overwriting unrelated user files.

set -e

if [ ! -f /workspace/Makefile ]; then
    if [ -z "$(ls -A /workspace 2>/dev/null)" ]; then
        cp -r /sdk/. /workspace/
    else
        echo "ticktrace: /workspace has files but no Makefile." >&2
        echo "ticktrace: mount a clone of rp-asm at /workspace, or run from an empty directory." >&2
        exit 1
    fi
fi

exec "$@"
