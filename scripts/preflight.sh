#!/bin/sh
set -eu

need() { command -v "$1" >/dev/null 2>&1; }
fail() { printf "✗ %s\n" "$1"; exit 1; }

for b in podman sops age; do
  need "$b" || fail "missing dependency: $b (run ./bootstrap.sh --install)"
done

# RAM ≥ 512MB
MEM="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
[ "$MEM" -ge 524288 ] || fail "not enough RAM (need ≥512MB)"

# Disk ≥ 1GB
DISK="$(df . | awk 'NR==2 {print $4}')"
[ "$DISK" -ge 1048576 ] || fail "not enough disk space (need ≥1GB)"
