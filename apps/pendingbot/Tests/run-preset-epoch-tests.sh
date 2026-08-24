#!/usr/bin/env bash
# Compile + run the standalone PresetEpoch tests, once per device timezone.
#
# Why not xcodebuild test: this branch has no iOS unit-test target yet (same
# situation as run-model-reveal-policy-tests.sh). PresetEpoch.swift and
# RelativeMessageTime.swift import nothing but Foundation on purpose, so swiftc
# alone can exercise them — in ~2s, with no simulator involved. Port these into
# the real target once it lands on main.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O \
  "$here/../Sources/Components/PresetEpoch.swift" \
  "$here/../Sources/Components/RelativeMessageTime.swift" \
  "$here/PresetEpochTimeTests.swift" \
  -o "$out/preset-epoch-tests"
for tz in Asia/Shanghai America/New_York; do
  TEST_TZ="$tz" "$out/preset-epoch-tests"
done
