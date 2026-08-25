#!/usr/bin/env bash
# Compile + run the standalone 模型名显示 tests — ModelRevealPolicy (该不该
# 显示真名) + ConversationHeaderLabel (那一行字怎么拼)。
#
# Why not xcodebuild test: this branch predates the iOS unit-test target
# (feat/ios-unit-tests). ModelRevealPolicy.swift imports nothing but
# Foundation on purpose, so swiftc alone can exercise it — in ~2s, with no
# simulator involved. Port to the real target once it lands on main.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O \
  "$here/../Sources/Features/Message/ModelRevealPolicy.swift" \
  "$here/../Sources/Features/Message/ConversationHeaderLabel.swift" \
  "$here/ModelRevealPolicyTests.swift" \
  "$here/ConversationHeaderLabelTests.swift" \
  -o "$out/policy-tests"
"$out/policy-tests"
