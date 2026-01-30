#!/bin/sh
set -eu

SVC="$1"

[ "$SVC" = "all" ] && {
  for d in services/*; do
    sh "$0" "$(basename "$d")"
  done
  exit 0
}

DIR="services/$SVC"
CFG="$DIR/service.yaml"
ENV="$DIR/service.env.sops"

[ -d "$DIR" ] || exit 1
[ -f "$CFG" ] || exit 1
[ -f "$ENV" ] || exit 1

ENV_PLAIN="$(mktemp)"
trap 'rm -f "$ENV_PLAIN"' EXIT

sops -d "$ENV" >"$ENV_PLAIN"

podman rm -f "$SVC" 2>/dev/null || true

podman run -d \
  --name "$SVC" \
  --env-file "$ENV_PLAIN" \
  --replace \
  $(grep -v '^#' "$CFG")
