#!/usr/bin/env bash
# iOS 可编译性 + 「平台专属域真的不在 iOS」核验（CI 与本地跑同一份）。
#
# 用法：bash tool/ci/ios.sh
# 为什么要符号表而不只看编译通过：`#if os(macOS)` 的域「能编译」只证明没有悬空
# 符号，证明不了「域真的不在 iOS 产物里」——本仓的既定纪律（见 HANDOFF）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DERIVED="${IOS_DERIVED_DATA:-/tmp/swiftus-ios-derived}"
DEST='generic/platform=iOS'

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCHEMES=(
  SwiftusCore SwiftusFoundation SwiftusCredentials SwiftusLLM SwiftusCompaction
  SwiftusSchedule SwiftusCron SwiftusSearch SwiftusSkill SwiftusMCP SwiftusAgent
  SwiftusTasks Swiftus
)
# SwiftusDemo 不是 product，没有 scheme，不在此列。

log "iOS 编译：${#SCHEMES[@]} 个 target"
for scheme in "${SCHEMES[@]}"; do
  if xcodebuild -scheme "$scheme" -destination "$DEST" -derivedDataPath "$DERIVED" build \
      2>&1 | grep -q 'BUILD SUCCEEDED'; then
    printf '  %-20s OK\n' "$scheme"
  else
    xcodebuild -scheme "$scheme" -destination "$DEST" -derivedDataPath "$DERIVED" build 2>&1 | tail -20 >&2
    fail "$scheme 在 iOS 上编译失败"
  fi
done

# ── 符号表核验：平台专属域不该出现在 iOS 产物里 ──
log "符号表核验：平台专属域不应出现在 iOS 产物中"
assert_absent_symbol() {
  local object="$1" symbol="$2" count
  if [[ ! -f "$object" ]]; then
    fail "找不到 iOS 产物：$object"
  fi
  count="$(nm "$object" 2>/dev/null | grep -c "$symbol" || true)"
  if [[ "$count" != "0" ]]; then
    fail "$symbol 在 $object 里出现 $count 次（平台专属域本该整体缺席）"
  fi
  printf '  %-22s 缺席 ✓\n' "$symbol"
}

object_of() {
  find "$DERIVED" -name "$1.o" -path '*Debug-iphoneos*' 2>/dev/null | sed -n '1p' || true
}

assert_absent_symbol "$(object_of SwiftusMCP)" "StdioTransport"
assert_absent_symbol "$(object_of SwiftusFoundation)" "ShellExecutor"

printf '\n\033[32m全部通过\033[0m\n'
