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

产物写入 `spec/fixtures/s*/` 并直接提交进仓。导出器自带导出侧校验
（成功场景的不变式 violations 必须为空、违规场景必须非空），校验失败即报错不写盘。

## 归一化规则（语言相关表面差异不入 fixtures）

- `compactionId` 按日志中首次出现顺序替换为 `<cmp-1>` / `<cmp-2>` …；Swift 侧运行器做同样归一化后比对结构（校验「三事件同身份」，不比具体值）；
- `compaction/end` 的 `error` 值剥掉 Dart `StateError` 的 `Bad state: ` 前缀；Swift 侧按 contains 子串比对（错误展示串的语言相关部分不是规格）；
- 事件的 `time` 与 `id` 不入 fixture。

S17（任务中心）另有一组专用归一化：

- 任务 id 按**创建顺序预登记**后替换为 `<task-1>` / `<task-2>` …（Dart id 内嵌墙钟微秒；不预登记则归一化结果依赖投影顺序）；
- `createdAt` / `startedAt` / `finishedAt` 不入投影，改为 `hasStartedAt` / `hasFinishedAt` 布尔；
- `result` 只在 JSON 形态可比时入投影（不可编码值退化为字符串是语言相关展示面）；`error` 只投影形态（`errorShape`）且**只取持久化后的载荷**——内存态错误值的形态随语言类型系统而异，内容断言由用例的显式布尔承担；
- 被信号杀死的进程退出码随平台而异（macOS/Linux 为 -9），只投影 `resultKeys`；
- **投递时机不进 fixture**：广播流（`changes`）的条数是 `await` 交错产物，两次导出可能不同——这类断言改由 Swift 侧单元测试承担。

## 同步纪律

conatus 侧语义变更（对齐新 tag）时重新导出并提交；Swift 侧与 Dart 侧 fixtures 同步过测才算该变更完成。
