#!/usr/bin/env bash
# fixtures 漂移核验：从 tool/export_fixtures/CONATUS_PIN 钉住的 conatus 提交
# 重跑全部导出器，确认 spec/fixtures 逐字不变。
#
# 用法：bash tool/ci/fixtures.sh
# 用途：AGENTS.md 的演进纪律是「Dart 侧语义变更时先改共享 fixtures，两端同步过测
# 才算该变更完成」——这条纪律需要一个机器可判的门禁，否则只能靠人记得重导。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PIN_FILE="tool/export_fixtures/CONATUS_PIN"
CONATUS_REPO="${CONATUS_REPO:-https://github.com/Fi2zz/conatus.git}"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

PIN="$(grep -oE '^[0-9a-f]{40}' "$PIN_FILE" || true)"
[[ -n "$PIN" ]] || fail "$PIN_FILE 里没读到 40 位提交号（格式：一个 sha 单独一行）"
log "conatus 锚点：$PIN"

# 本地已有 conatus checkout 时优先用它（省一次 clone，且行为与开发者一致）。
if [[ -n "${CONATUS_ROOT:-}" ]]; then
  CONATUS="$CONATUS_ROOT"
  log "用指定的 CONATUS_ROOT：$CONATUS"
  if [[ "$(git -C "$CONATUS" rev-parse HEAD)" != "$PIN" ]]; then
    fail "CONATUS_ROOT 的 HEAD 不是 ${PIN}（钉住版本才能判漂移）"
  fi
else
  CHECKOUT="$(mktemp -d)/conatus"
  log "克隆 conatus 到 $CHECKOUT"
  git clone --quiet --filter=blob:none --no-checkout "$CONATUS_REPO" "$CHECKOUT"
  git -C "$CHECKOUT" checkout --quiet "$PIN"
  CONATUS="$CHECKOUT"
fi

log "dart pub get"
(cd "$CONATUS" && dart pub get >/dev/null)

[[ -f "$CONATUS/.dart_tool/package_config.json" ]] \
  || fail "conatus 缺 .dart_tool/package_config.json，dart pub get 没成功"

log "重跑全部导出器"
CONATUS_ROOT="$CONATUS" bash tool/export_fixtures/export.sh >/dev/null \
  || fail "导出器失败"

log "比对 spec/fixtures"
changed="$(git status --porcelain spec/fixtures/ || true)"
if [[ -n "$changed" ]]; then
  printf '%s\n' "$changed" >&2
  git diff --stat spec/fixtures/ >&2
  fail "fixtures 与钉住的 conatus 提交不一致——要么 Dart 侧语义变了，要么该更新 CONATUS_PIN"
fi

log "fixtures 与 conatus@$PIN 逐字一致 ✓"
printf '\n\033[32m全部通过\033[0m\n'
