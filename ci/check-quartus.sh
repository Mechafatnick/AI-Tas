#!/usr/bin/env bash
set -euo pipefail

EXPECTED_MAJOR="24.1"
if ! command -v quartus_sh >/dev/null 2>&1; then
  echo "quartus_sh not found; install Quartus Prime Lite ${EXPECTED_MAJOR} on this runner." >&2
  exit 1
fi

VERSION="$(quartus_sh --version 2>&1 || true)"
echo "$VERSION"
case "$VERSION" in
  *"24.1"*) ;;
  *)
    echo "Expected Quartus 24.1.x; refusing to build with a different major/minor." >&2
    exit 1
    ;;
esac
