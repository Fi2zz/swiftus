# fixture 导出器（tool/export_fixtures）

以 Dart 侧行为为准绳导出 golden fixtures（方案书 §3.2；fixtures 不是手写）。

## 前置

- 本地 conatus checkout（默认与 swiftus 同级目录，即 `../conatus`；可用 `CONATUS_ROOT` 环境变量指定）；
- 该 checkout 已执行 `dart pub get`（存在 `.dart_tool/package_config.json`）；
- Dart SDK ≥ 3.6。

## 用法

```bash
bash tool/export_fixtures/export.sh
```

产物写入 `spec/fixtures/s7/*.json` 并直接提交进仓。导出器自带导出侧校验
（成功场景的不变式 violations 必须为空、违规场景必须非空），校验失败即报错不写盘。

## 归一化规则（语言相关表面差异不入 fixtures）

- `compactionId` 按日志中首次出现顺序替换为 `<cmp-1>` / `<cmp-2>` …；Swift 侧运行器做同样归一化后比对结构（校验「三事件同身份」，不比具体值）；
- `compaction/end` 的 `error` 值剥掉 Dart `StateError` 的 `Bad state: ` 前缀；Swift 侧按 contains 子串比对（错误展示串的语言相关部分不是规格）；
- 事件的 `time` 与 `id` 不入 fixture。

## 同步纪律

conatus 侧语义变更（对齐新 tag）时重新导出并提交；Swift 侧与 Dart 侧 fixtures 同步过测才算该变更完成。
