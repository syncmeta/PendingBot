#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_PRODUCT="PendingBotMac"
PACKAGE_PATH="apps/macos/PendingBot"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

build_package() {
  cd "$REPO_ROOT"
  swift build --package-path "$PACKAGE_PATH"
}

run_app() {
  cd "$REPO_ROOT"
  swift run --package-path "$PACKAGE_PATH" "$APP_PRODUCT"
}

case "$MODE" in
  --verify|verify)
    build_package
    ;;
  run)
    build_package
    run_app
    ;;
  *)
    echo "usage: $0 [run|--verify]" >&2
    exit 2
    ;;
esac
