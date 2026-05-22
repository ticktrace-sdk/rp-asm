# syntax=docker/dockerfile:1.7
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Amken LLC <https://www.amken.us>
#
# ticktrace SDK container image. Two stages:
#
#   slim  - just enough to build firmware ( binutils-arm-none-eabi, make,
#           python3 for tools/uf2.py ). ~250 MB.
#   full  - slim + Unicorn + QEMU + Go + pytest, enough to run the full
#           T1+T2+test-tools tiers. ~800 MB.
#
# Build slim (default):
#   docker buildx build --target slim -t ticktrace/sdk:slim .
#
# Build full:
#   docker buildx build --target full -t ticktrace/sdk:full .
#
# Multi-arch build (used by CI):
#   docker buildx build --platform linux/amd64,linux/arm64 --target slim ...
#
# Run examples:
#   docker run --rm -v "$PWD":/workspace ticktrace/sdk:slim
#   docker run --rm -v "$PWD":/workspace ticktrace/sdk:slim make examples
#
# If your host UID != 1000 (e.g. Linux native users), pass --user so build
# artefacts aren't root-owned:
#   docker run --rm -v "$PWD":/workspace --user $(id -u):$(id -g) ticktrace/sdk:slim


# ---------------------------------------------------------------------------
# Stage 1: slim - build-only
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS slim

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# binutils-arm-none-eabi - the only toolchain we need (no C, no HAL).
# make - the SDK build is a Makefile.
# python3 + python3-pip - tools/uf2.py and tools that wrap the build.
# ca-certificates - so curl/pip can verify TLS when users extend the image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        binutils-arm-none-eabi \
        make \
        python3 \
        python3-pip \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root user. UID 1000 matches the most common Linux desktop UID, which
# means volume-mounted artefacts (build/) come out owned by the host user
# without needing --user on most systems. Users with a different UID pass
# --user $(id -u):$(id -g) at run time.
RUN useradd --uid 1000 --create-home --shell /bin/bash ticktrace \
 && mkdir -p /workspace \
 && chown -R ticktrace:ticktrace /workspace

USER ticktrace
WORKDIR /workspace

# Sensible default: 'docker run image' = 'make'. Override with any command:
#   docker run image make examples
#   docker run image bash
CMD ["make"]


# ---------------------------------------------------------------------------
# Stage 2: full - slim + tests (T1 Unicorn + T2 QEMU + test-tools Go)
# ---------------------------------------------------------------------------
FROM slim AS full

USER root

# Go version pinned to match what test-tools expects (go.mod: go 1.24).
ARG GO_VERSION=1.24.4
ARG TARGETARCH

# QEMU for T2, system Python deps (pinned to match tests/unicorn/requirements.txt).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        qemu-system-arm \
        curl \
 && rm -rf /var/lib/apt/lists/*

# Python test deps. --break-system-packages mirrors the CI workflow's approach
# on Debian/Ubuntu where pip refuses to write into the system Python without
# it; safe inside a container.
RUN python3 -m pip install --no-cache-dir --break-system-packages \
        'unicorn>=2.0.1' \
        'pyelftools>=0.30' \
        'pytest>=7.0'

# Go toolchain for test-tools (cd tools && go test ./...).
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) goarch=amd64 ;; \
        arm64) goarch=arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/go.tgz \
        "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz"; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    /usr/local/go/bin/go version

ENV PATH=/usr/local/go/bin:${PATH} \
    GOPATH=/home/ticktrace/go \
    GOCACHE=/home/ticktrace/.cache/go-build

USER ticktrace
WORKDIR /workspace

CMD ["make"]
