#!/usr/bin/env bash
# 主验证：debug / release 构建与测试 + 离线 Demo 冒烟（CI 与本地跑同一份）。
#
# 用法：bash tool/ci/verify.sh [build|test|demo|all]
#   不带参数 = all。CI 按阶段拆成多个 step，这样「哪一步红了」不用翻日志。
# 约定见 AGENTS.md「验证命令」一节。要点：
#   * release 零警告是硬门槛（方案书 §四的波次出口）；
#   * release 测试**必须双跑**（坑 #8：release 优化下时序会变，单跑会偶发绿）；
#   * 测试用例数必须 > 0（swift-testing 过滤失配时「0 例通过」也返回 0，
#     那样参数化空跑会被当成通过——本仓已吃过两次，见 HANDOFF）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 零警告门槛 ───────────────────────────────────────────────
# swift build 的警告走 stderr；空输出是「零警告」的目标态。
build_zero_warnings() {
  local config="$1" out
  out="$(mktemp)"
  if ! swift build -c "$config" >"$out" 2>&1; then
    cat "$out" >&2
    fail "swift build -c $config 失败"
  fi
  # 清干净重来：只抓干净构建的警告，编译中间的进度行不算。
  rm -rf .build/"$config"
  swift build -c "$config" >"$out" 2>&1 || { cat "$out" >&2; fail "swift build -c $config 失败"; }
  local warnings
  warnings="$(grep -c 'warning:' "$out" || true)"
  rm -f "$out"
  if [[ "$warnings" != "0" ]]; then
    printf '\033[31m✗ release/debug 构建出现 %s 条警告\033[0m\n' "$warnings" >&2
    swift build -c "$config" 2>&1 | grep 'warning:' | sed -n '1,20p' >&2 || true
    fail "零警告是硬门槛（方案书 §四）"
  fi
  log "$config 构建：零警告 ✓"
}

# ── 测试（带「用例数 > 0」自检）─────────────────────────────
run_tests() {
  local config="$1" run out count
  run="${2:-1}"
  for ((i = 1; i <= run; i++)); do
    out="$(mktemp)"
    if ! swift test -c "$config" >"$out" 2>&1; then
      tail -60 "$out" >&2
      rm -f "$out"
      fail "swift test -c ${config}（第 $run/$run 次）失败"
    fi
    # swift-testing 的成功行：Test run with N tests in M suites passed
    count="$(grep -oE 'Test run with [0-9]+ tests' "$out" | grep -oE '[0-9]+' | tail -1 || true)"
    if [[ -z "$count" || "$count" == "0" ]]; then
      tail -30 "$out" >&2
      rm -f "$out"
      fail "swift test -c $config 只跑到 0 个用例（参数化失配？空跑会被当成通过）"
    fi
    rm -f "$out"
    log "$config 测试第 $run/$run 次：$count 例通过 ✓"
  done
}

# ── Demo 冒烟 ───────────────────────────────────────────────
# 断言「七段演示都跑到了」而不是逐字比对全文：任务 id / 时刻 / 源数量都随环境变。
demo_smoke() {
  local out
  out="$(mktemp)"
  if ! swift run swiftus-demo >"$out" 2>&1; then
    tail -40 "$out" >&2
    rm -f "$out"
    fail "swift run swiftus-demo 失败"
  fi
  local markers=(
    "=== 1. Agent Loop ==="
    "=== 2. 会话持久化（S4）==="
    "=== 3. 任务中心（S17）==="
    "=== 4. 提醒（S8）==="
    "=== 5. 定时任务（S9）==="
    "=== 6. 联网搜索（S20）==="
    "=== 7. MCP（S11）==="
    "demo__shout"                 # MCP server 的工具真被调了
    "落盘会话 id：[\"demo\"]"      # 会话真落盘了
    "本轮交付到会话：1 条"          # cron 交付端口真把记录送进了同一条会话
    "已装配 server：[\"demo\"]"
  )
  local marker
  for marker in "${markers[@]}"; do
    grep -qF -- "$marker" "$out" || {
      tail -40 "$out" >&2
      rm -f "$out"
      fail "Demo 输出缺少标记：$marker"
    }
  done
  # 联网搜索：断言 duckduckgo 在源列表里，不比对整个列表（runner 上有 Key 就多几个源）。
  grep -qE '已注册源：.*duckduckgo' "$out" || {
    tail -40 "$out" >&2
    rm -f "$out"
    fail "Demo 的联网搜索源里没有 duckduckgo（免 Key 降级应兜住）"
  }
  rm -f "$out"
  log "Demo 七段冒烟通过 ✓"
}

toolchain() {
  log "工具链"
  # 注意：不要写 `swift --version | head -2`——`head` 提前关管道，上游收到 SIGPIPE(141)，
  # 而 `set -o pipefail` 把它判成失败，脚本会随机猝死（本地已复现，CI 上同样会炸）。
  local swift_ver
  swift_ver="$(swift --version 2>&1 || true)"
  printf '%s\n' "$(printf '%s\n' "$swift_ver" | sed -n '1,2p')"
  printf '%s\n' "$(xcodebuild -version 2>&1 | sed -n '1p' || true)"
}

stage_build() {
  build_zero_warnings debug
  build_zero_warnings release
}

stage_test() {
  run_tests debug 2
  # 坑 #8：release 优化会改时序，双跑是纪律不是可选。
  run_tests release 2
}

stage_demo() { demo_smoke; }

case "${1:-all}" in
  build) toolchain; stage_build ;;
  test)  stage_test ;;
  demo)  stage_demo ;;
  all)   toolchain; stage_build; stage_test; stage_demo ;;
  *)     fail "未知阶段：$1（可选 build / test / demo / all）" ;;
esac

printf '\n\033[32m全部通过\033[0m\n'
