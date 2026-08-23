#!/usr/bin/env bash
# 编译 + 运行 AppleWebCallback 的独立单测。
#
# 为什么不是 xcodebuild test：本分支还没有 iOS 单测 target
# （feat/ios-unit-tests 未合 main）。AppleWebCallback.swift 刻意只 import
# Foundation，所以 swiftc 单独就能考它 —— 两秒，不起模拟器。
# 真 target 落地后把用例平移过去、删掉这个脚本。
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O \
  "$here/../Sources/Networking/AppleWebCallback.swift" \
  "$here/AppleWebCallbackTests.swift" \
  -o "$out/apple-web-callback-tests"
"$out/apple-web-callback-tests"
