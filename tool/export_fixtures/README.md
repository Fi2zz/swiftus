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

S12（凭据全量）另有一组专用归一化：

- **用例自带输入**：文件内容 / 响应体 / 状态码 / 网络故障开关 / 连接配置都写进 `input`，运行器据此驱动替身——输入藏在导出器里等于把 fixture 和导出器绑死，两端无法独立重放；
- **凭据表与键分开投影**：`keys` 含已过期的键，`get` 对过期键视为没有，两者一起投影才能锁住「过期即视为没有」；
- **AWS 签名头只投影稳定形状**：算法 / accessKey / dateStamp 形态 / region / service / SignedHeaders / 签名长度；日期与签名逐次变化，不入 fixture。载荷字节固定（`{"SecretId":"…"}`，斜杠不转义）故 `X-Amz-Content-Sha256` 可逐字比对；
- Dart 侧文件来源遇非法 JSON 抛 `FormatException`（无机器码），fixture 如实记录，Swift 侧按 S12 §2 的 `invalid-source` 归一后比对。

S18（fs / shell）另有一组专用归一化：

- 临时根目录替换为 `<root>`，分隔符统一为 `/`；
- **版本令牌不比对具体串**（格式由实现自定、跨实现不可比），只断言「稳定 / 变化」这类语义；
- **退出码的符号是运行时细节**：Dart 被信号杀死给 `-9`，Foundation 给信号号（正数）——协议只锁「非 0」，被信号杀死的用例用 `input.signaledExit` 声明并只投影 `exitCodeIsNonZero`；
- `lstat` 的**类型**取链接自身而**大小**跟随链接（Dart 的实际行为，文档措辞与实现不一致），fixture 照实际行为导出；
- 缺失目标在「父目录事后创建」时身份键会变（照 Dart 实际行为，不修）。

## 同步纪律

conatus 侧语义变更（对齐新 tag）时重新导出并提交；Swift 侧与 Dart 侧 fixtures 同步过测才算该变更完成。
