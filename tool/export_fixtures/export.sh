#!/usr/bin/env bash
# S7 fixtures 导出：在本地 conatus checkout 上运行导出器（方案书 §3.2）。
# 前置：conatus checkout 已 dart pub get（默认与 swiftus 同级，或以 CONATUS_ROOT 指定）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONATUS_ROOT="${CONATUS_ROOT:-$ROOT/../conatus}"
CONFIG="$CONATUS_ROOT/.dart_tool/package_config.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "找不到 $CONFIG" >&2
  echo "请先在 conatus checkout（$CONATUS_ROOT）执行 dart pub get，或以 CONATUS_ROOT 指定其位置" >&2
  exit 1
fi
cd "$ROOT"
dart --packages="$CONFIG" tool/export_fixtures/export_s7.dart
