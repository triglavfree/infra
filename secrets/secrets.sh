#!/bin/sh
set -eu

[ -n "${SOPS_AGE_KEY_FILE:-}" ] || {
  echo "SOPS_AGE_KEY_FILE is not set"
  exit 1
}
