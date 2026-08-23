#!/usr/bin/env bash
# Compile + run the standalone SupabaseAnonWriteGuard tests.
#
# Why not xcodebuild test: same reason as run-model-reveal-policy-tests.sh —
# there's no iOS unit-test target yet, and the guard's predicate needs nothing
# but Foundation. Port to the real target once one lands on main.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O \
  "$here/../Sources/Log.swift" \
  "$here/../Sources/Networking/SupabaseAnonWriteGuard.swift" \
  "$here/SupabaseAnonWriteGuardTests.swift" \
  -o "$out/guard-tests"
"$out/guard-tests"
