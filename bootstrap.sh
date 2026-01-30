#!/bin/sh
set -eu

MODE="${1:-}"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--install" ]; then
  echo "usage: $0 --check | --install"
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1; }
say() { printf "• %s\n" "$1"; }
fail() { printf "✗ %s\n" "$1"; exit 1; }

detect_os() {
  [ -f /etc/os-release ] || fail "cannot detect OS"
  . /etc/os-release
  echo "$ID"
}

OS="$(detect_os)"
say "detected OS: $OS"
say "mode: $MODE"
echo

REQ="podman sops age git"
MISSING=""

for b in $REQ; do
  if need "$b"; then
    say "$b: present"
  else
    say "$b: missing"
    MISSING="$MISSING $b"
  fi
done

[ -z "$MISSING" ] && {
  say "all dependencies present"
  exit 0
}

[ "$MODE" = "--check" ] && exit 1

say "installing:$MISSING"
echo

case "$OS" in
  ubuntu|debian)
    sudo apt update
    sudo apt install -y podman sops age git
    ;;
  alpine)
    sudo apk add podman sops age git
    ;;
  void)
    sudo xbps-install -Sy podman sops age git
    ;;
  *)
    fail "unsupported OS: $OS"
    ;;
esac

say "installation complete"
