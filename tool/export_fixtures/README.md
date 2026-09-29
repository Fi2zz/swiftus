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

S19（Foundation 其余能力域）另有一组专用归一化：

- **timer 只投影计数与是否发生**（触发过几次、撤销后是否还触发、sleep 是否被中断），不投影具体间隔——间隔是时间，不是行为；节流 / 防抖的窗口边界由 Swift 侧受控驱动断言；
- **「值是空的」投影成布尔**：Dart 的 `null` 与 Swift 的 `.null` 都投影成 `valueIsNull`，不投原值；
- **错误类型不进 fixture**：`sleep` 中断的语义是「以错误结束而不是悬挂」，具体类型（`StateError` / `ContextDisposedError`）由 Swift 侧单元测试锁定；
- **控制台日志的 ISO 时刻归一为 `<time>`**（`showTime` 用例）：墙钟逐次变化，只比对行形状；
- **日志记号与导出器内部结构无关**（`on:` / `off:`），否则两端日志不可比；
- **投影可变对象要拷快照**：直接投活列表会把后续 dispose 的日志写进 fixture；
- **非零时区偏移的日期换算不进 fixtures**：Dart 只有 UTC 偏移能确定性构造（`DateTime.parse` 带偏移会归一到 UTC，`toLocal()` 依赖机器本地时区），渲染类用例固定 UTC 时刻，非零偏移由 Swift 侧注入偏移断言；
- **装载自检**：每个 kind 另有一条 Swift 用例断言「恰好命中一个 fixture 文件且用例非空」，防止参数化空跑全绿。

S9（Cron）另有一组专用归一化：

- **时刻逐字保留**：规则与到期判定是纯函数，用例自带固定 `now` / `startedAt` / `firedAt`，投影里的 UTC ISO 串直接比对（不归一化、不「相对现在」）；
- **生成的 id 不入 fixture**：`task-<base36 毫秒>-<随机后缀>` 与 `run-<seq>-<base36 毫秒>` 含随机与墙钟，只断言**形状**与唯一性 / seq 连续；
- **framing 逐字比对**：触发消息是防注入协议文本，逐行锁死（含空行与 `<task>` 包裹）；
- **工具结果按「键排序」的规范 JSON 文本比对**（`_canonicalJson`，与模型实际看到的一致）：Swift 侧 `JSONValue.jsonData()` 走 `JSONSerialization(.sortedKeys)`，而 `jsonEncode` 保插入序，直接比会整条用例红；
- **用例自带输入**（含有状态场景的操作表）：CRUD 的操作序列、运行时的三个子场景、账本的输入全部写进 fixture 的 `input`；Swift 侧按同一张表驱动。输入藏在导出器里等于把 fixture 与导出器绑死，两端无法独立重放（另有一条 Swift 用例断言「每条用例都有 input」）；
- **投影可变对象要取当时快照**：Dart 的 `CronRunRecord` 是可变对象，导出时 `toJson()` 会把后续 `finish` 的结果写进本该是「刚交付」的投影（本项目踩过一次）——序列化结果在对应时刻 `Map.of(...)` 拷一份再往下走；
- **到期任务用 `at` 而不是 `every` 造**：`every` 的锚点是服务装配时刻，用它造「应当立刻到期」的任务会因未到间隔而**整组用例空跑**（本项目踩过一次，导出的期望值全是 0，测试看着过、实际什么都没验）；注意 `at` 任务**只触发一次**，要反复触发得让墙钟与手动时间驱动一起推进；
- **手动 tick 的运行时不要先 `dispose()`**：来源的 `tick()` 在循环开头检查 `_disposed`，dispose 之后调用会直接返回（本项目踩过一次）；只把定时器间隔拉到极大来保证安静，用完再 `dispose()`；
- **依赖本地时区的导出器必须钉死时区**：S9 的 `daily` 与小时级 cron 语义基于本地时区，导出器自检 `TZ=UTC`（`export.sh` 已带上），否则期望值随导出机器的时区漂移——本项目踩过一次：`daily 09:00` 在东八区落到 `01:00Z`、四年搜索还命中了错日。fixture 根里的 `localZone` 字段声明该域使用的时区，Swift 侧运行器按它注入；
- **装载自检 + 空跑守卫**：每个 kind 一条「恰好命中一个 fixture 文件且用例非空」；每个运行器结尾再断言「至少比对过一次」——投影键被裁光、解析失败走 `continue` 都会让一条都没比，而参数化用例在这种情况下表现为全绿；

S20（联网搜索与抓取）另有一组专用归一化：

- **请求形状投影解码后的查询项**（不投原始 URL 串）：Dart 的 `Uri.queryParameters` 与 Swift 的 `URLComponents.queryItems` 在 `+` / `%20` 上不完全一致，逐字比 URL 会把用例绑死在编码细节上；方法 / 主机 / 路径 / 头名 / 体这些语义面才进 fixture；
- **头名小写并剔掉传输层头**：Dart 的 `http.Headers` 大小写不敏感，URLSession 还会自动加 `content-length` / `accept-encoding`——头名列表要可比就得两边都归一（值的投影不受影响）；
- **中文 fixture 必须显式声明 charset**：`http.Response.bytes` 不带 `content-type: …; charset=utf-8` 时按 latin1 解码，中文正文会变成乱码并被照抄进期望值；
- **传输失败只投影消息前缀**（`errorPrefix`）：失败原因是语言相关的运行时描述（Dart 的 `ClientException` 文案 vs Foundation 的 `localizedDescription`），锁前缀即可；
- **失败用例必须真的失败**：fetch_url 的「抓取失败」用例第一版与成功用例共用恒返回 200 的 client，期望值里落下的其实是正文——用例会「以失败的名字通过」；
- **用到 URL 桩的 kind 必须走单条串行用例**：桩注册表是进程级单例而 swift-testing 并发跑用例；用 `NSLock` 串行会在协作线程池上死锁（持锁线程占满 → URLSession 回调拿不到线程 → 全部挂起），端点又必须与 fixture 逐字一致（没法换主机隔离），故只能把三个 kind 合进一条 `@Test` 顺序跑；
- **桩按 host+port+path 分桶**（不只 authority）：S20 的 fixture 端点都挂在同一探测主机上。

## 同步纪律

conatus 侧语义变更（对齐新 tag）时重新导出并提交；Swift 侧与 Dart 侧 fixtures 同步过测才算该变更完成。
