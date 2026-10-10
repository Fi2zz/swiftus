# S9 · Cron 定时任务

版本：v1.0 · 日期：2026-09-29 · 来源：conatus_cron（13 个源文件：`cron_types` / `cron_errors` / `cron_parse` / `cron_rules` / `cron_registry` / `cron_history` / `cron_book` / `cron_storage` / `json_cron_storage` / `cron_message` / `cron_notify` / `cron_tools` / `cron_edit_tools` / `cron_runtime`）
语言中立规格。Swiftus 实现注记见文末。
前置：S2（上下文树与可逆效应）、S4（会话事件）、S5（工具管线）、S8（调度选择器与 IANA 时区——两者都做时区/DST 语义，本规格只做「本地墙钟 + 5 段 cron」）。

范围说明：把「到点把任务提示以**固定 framing** 交给宿主注入的交付端口执行」这套语义忠实搬过来——**调度器不执行任何东西，只负责算时段、渲染 framing、投递、记账**。framing 明确告知模型「这是自动化任务，不是用户消息」，是防注入设计的一部分。

## 1. 词汇与常量

- 规则键（四选一）：`at`（一次性 ISO 8601 时刻）/ `every`（固定间隔秒数）/ `daily`（本地 `HH:MM`）/ `cron`（标准 5 段表达式）；
- 来源：`config`（宿主配置声明，**运行时不可增删改**）/ `dynamic`（运行时添加并持久化）；
- 运行记录状态：`delivered`（已交付宿主，等执行结果）/ `running`（事件流语义保留，本端口不主动置位）/ `completed` / `failed`；
- 常量：最小 `every` 间隔 **10 秒**；内存与文件两侧历史上限 **500**；摘要最大长度 **300 字符**；存储协议版本 **1**；
- 任务 id 形状：`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`（字母或数字开头）；
- `daily` 形状：本地 24 小时制 `^([01]\d|2[0-3]):([0-5]\d)$`；
- 自动生成的 id 形状：`task-<毫秒 base36>-<4 位 base36 随机后缀>`；
- 记录 id 形状：`run-<seq>-<毫秒 base36>`，`seq` **单调连续**；
- 错误码（封闭集，工具结果的 `code` 直接取这些常量）：`invalid-task` / `duplicate-id` / `not-found` / `config-task` / `delivery-unavailable` / `internal_error`。

## 2. 内部记录与模型可见视图

- `CronTask`（内部可变记录）：`id`、`prompt`、四个规则字段、`sessionId?`、`enabled`（声明值）、`origin`；**只活在内存**的还有 `enabledOverride?`（与声明值一致时归空）、`lastRunAt?`、`firedAt?`、`cronParsed?`（解析缓存）、`cronNext?`（下一触发分钟缓存）；
- `CronTaskView`（稳定对外形状，工具结果）：`id`、`prompt`、`schedule`（**四选一的对象**：`{at}` / `{everySeconds}` / `{daily}` / `{cron}`）、`enabled`（**覆盖优先**于声明值）、`origin`、`sessionId?`、`lastRunAt?`、`firedAt?`、`nextRunAt?`（无待触发时为空）；日期一律 **UTC ISO 串**；
- 生效启停值 = `enabledOverride ?? enabled`。

## 3. 输入校验（纯函数，返回消息或空）

顺序固定，先 id 再形状再规则：

1. **id**：必须是字符串且匹配 id 形状，否则 `invalid task id: <值描述>`（字符串按 JSON 转义给出，非字符串按字面量）；
2. **prompt**：必须是非空白字符串，否则 `task "<id>" needs a non-empty prompt`；
3. **规则计数**：四个规则键里**恰好一个**为「生效」，否则 `task "<id>" must set exactly one of at / every / daily / cron`。生效判定用 JS 真值语义（`at` / `daily` / `cron` 按真值——空串、0、false 都算「没填」；`every` 按**非 nil**）；
4. `at`：可解析为时刻，否则 `task "<id>" has an unparseable at value`；
5. `every`：必须是**有限数值**且 `>= 10`，否则 `task "<id>" every must be a number >= 10`；
6. `daily`：匹配 `HH:MM`，否则 `task "<id>" daily must be "HH:MM" (24h)`；
7. `cron`：能解析为合法 5 段表达式，否则 `task "<id>" has an invalid cron expression (want 5 fields: minute hour day month weekday)`。

## 4. cron 表达式引擎

- 5 段字段范围：分 `0-59`、时 `0-23`、日 `1-31`、月 `1-12`、周 `0-7`（**7 归一为 0**，都表示周日）；
- 字段片段支持 `*`、列表 `a,b`、范围 `a-b`、步进 `*/n` / `a-b/n` / `a/n`（`a/n` 按 Vixie cron 展开为 `a..max`）；步进 `< 1` 非法；越界（`lo < min`、`hi > max`、`lo > hi`）非法；任一片段非法 → 整个字段非法；字段非法 → 表达式非法；段数不等于 5 → 非法；
- 解析结果记 5 个允许值集合 + `domStar` / `dowStar`（该字段是否**裸 `*`**）；
- 匹配（**本地时间**）：分 ∧ 时 ∧ 月 ∧ 日/周；**日与周同时受限时「任一匹配」**，否则两者都要匹配；
- `nextSlot(expr, after)`：`after` 之后第一个匹配的本地分钟（严格大于，秒与毫秒截断后 +1 分钟起算）；搜索上限 **4 个闰年**的毫秒数，超出无匹配。

## 5. 到期判定与下次触发（纯函数，now / startedAt / firedAt 一律传入）

- `at`：已消费（`firedAt` 非空）→ 不触发；否则 `now >= 时刻` 即到期，时段就是那一刻；
- `every`：时段 = `(lastRunAt ?? startedAt) + every`；`now` 未到 → 不触发。**未运行过的任务以服务装配时刻 `startedAt` 为锚点**；
- `daily`：今天本地的 `HH:MM` 为时段；`now` 未到 → 不触发；**已运行过且 `lastRunAt >= 该时段` → 不再触发**（今天这一格已消费）。因此**服务整天错过该时段也会补发一次**；
- `cron`：时段 = 缓存的下一触发分钟（缓存空则按 `lastRunAt ?? startedAt - 1 分钟` 重算并写回）；`now` 未到 → 不触发；
- 停用（生效启停为假）时**一律不触发**，`nextRunAt` 也为空；
- `nextRunAt`（展示用）：`at` 未消费时为那一刻，否则空；`every` 为 `(lastRunAt ?? startedAt) + every`；`daily` 为今天该时刻——若今天这格已消费则**顺延一天**；`cron` 为缓存的下一分钟。

## 6. 任务注册表（服务键 `cron`）

- **装配顺序**（与来源一致）：持久化的动态任务 → 配置静态任务 → 运行戳（`lastRunAt` / `firedAt`）→ 启停覆盖；单条装载失败（非法或重 id）**跳过并告警**，不影响其余任务；
- `addDynamic`：id 缺省或空串时自动生成（`task-<base36 毫秒>-<4 位随机>`，最多试 100 次避免撞 id）；`sessionId` 缺省时取调用方会话绑定；
- 新增校验失败 → `invalid-task`；id 已存在 → `duplicate-id`（`task "<id>" already exists`）；
- `requireTask` 不存在 → `not-found`（`no task with id "<id>"`）；**对配置任务做增删改** → `config-task`（`task "<id>" comes from config; <verb> it there`）；
- 编辑：patch 命中任一规则键即视为**改动排期**——整组规则替换并**重置运行戳**（`lastRunAt` / `firedAt` 清空）；只改 prompt 不重置；
- `setEnabled`：与声明值一致时**覆盖归空**（回到声明值）；
- 删除：不存在 → `not-found`；配置任务 → `config-task`；
- **持久化只写显式字段表**（`id` / `prompt` / 四规则 / `sessionId` / `enabled`），**内部缓存（解析结果、下一触发分钟）永不落盘**；运行戳与启停覆盖另存两张表。

## 7. 运行历史

- 记录字段：`id` / `seq` / `taskId` / `prompt`（内容快照）/ `sessionId?` / `scheduledFor` / `firedAt` / `status` / `excerpt?` / `endReason?` / `startedAt?` / `completedAt?`；
- 账本**惰性加载**，内部旧记录在前，**对外列表最新在前**；
- `seq` **单调连续**：预分配标识即占用 seq，交付被拒时**归还**（仅当它是最新分配的那次才归还，保持连续）；
- 追加后整体封顶 **500** 条（从头部裁剪）并原子重写；加载时从最大 seq 续接；
- `finish(recordId, ok, excerpt?)`：推进到 `completed` / `failed`、记完成时刻、摘要截断到 **300 字符**；记录不存在 → 返回空（调用方据此静默）；
- `list(limit?)`：`limit` 缺省或 `<= 0` → **100**；超过 500 → 封顶 500。

## 8. 交付与运行时

- 交付端口签名：`(recordId, framing, task) -> 是否成功入队`。**返回假或抛错都不消费时段**，下个 tick 重试（抛错走告警通道）；**返回假**时告警文案说明「到期但投递被拒，下 tick 重试」；
- 成功交付后收尾（`commitFire`）：写 `lastRunAt`；`at` 任务另写 `firedAt`；**cron 任务的下一分钟缓存失效**；落盘任务表；追加一条 `delivered` 记录；
- 渲染 framing（**逐行固定，不许改写**）：
  ```
  [cron] Scheduled task "<id>" fired.
  Scheduled for: <UTC ISO>
  Fired at: <UTC ISO>

  This is an automated task submitted by the cron plugin, not a message from the user.
  Execute the task inside <task> now, then report the result concisely.

  <task>
  <prompt 原文>
  </task>
  ```
- 运行时：启动后 **3 秒**首 tick，之后每 **15 秒**一次（`tickSeconds < 1` 按 1 处理）；**每个任务独立隔离**，单任务故障只告警不影响其他；**同一时刻只允许一个 tick 在跑**（重入的 tick 直接跳过）；`dispose` 幂等，取消两个定时器、进行中的交付自然结束、不再触发新 tick；
- `runTaskNow(id)`：立即交付（宿主手动触发）；任务不存在 → `not-found`；投递不可用 → `delivery-unavailable`（`no delivery target is available to receive the task`）；
- `finishRun(recordId, ok, excerpt?)`：推进记录后，若装配了通知端口则发系统通知（标题 `定时任务完成：<prompt>` / `定时任务失败：<prompt>`，正文取摘要，无摘要用 prompt）。

## 9. 存储端口

- `CronStorage`（与 FileSystem / ShellExecutor 同构的**能力缝**）：`loadTasks() -> 快照`（动态任务原文 + 运行戳 + 启停覆盖）、`saveTasks(...)`、`loadHistory()` / `saveHistory(...)`（整体重写）；
- 读取约定**宽容降级**：缺失视为空、损坏告警后视为空；**写入失败不得抛出**（调度不该因存储故障中断）；
- 本地实现：任务表与历史各一个 JSON/JSONL 文件，历史**惰性加载**、追加后整体封顶并原子重写。

## 10. 工具（五个，均经 S5 管线注册）

| 工具 | 风险 | 参数 |
|---|---|---|
| `cron_list` | low | 无 |
| `cron_history` | low | `limit`（整数，说明「最多返回多少条，默认 20、最新在前」） |
| `cron_add` | medium | `id` / `prompt` / `at` / `every` / `daily` / `cron` / `session_id` / `enabled` |
| `cron_update` | medium | `id`（必填）/ `prompt` / `at` / `every` / `daily` / `cron` / `session_id` / `enabled` |
| `cron_remove` | medium | `id`（必填） |

- 说明文案面向模型（「什么时候该用」），与 dsh-cron 保持一致；
- 失败一律以 `code` + 消息的**结果值**返回（S5 纪律：不在管线里外抛）。

## 11. 有意偏离

- **`CronStorage` 的历史写入形状**：Dart 侧历史按「追加一行」暴露，本移植改为「整体重写」（与 §7 的封顶原子重写一致），端口语义不变；
- **无时区信息的 `at` 串按 UTC 解释**：来源的 `DateTime.tryParse` 把 `2026-03-09T09:00:00` 这类无偏移串当作**进程本地时区**；本移植固定按 UTC 解释——规则函数是纯函数、不持有环境时区，按机器时区解释会让同一份配置在不同机器上触发时刻不同。需要特定时区的宿主应自己带上偏移；
- **预分配记录标识前先加载账本**：来源的 `allocateRef` 不触发账本加载，`seq` 仍是从 0 起的初值，于是「重启后第一次交付」会复用磁盘上已有记录的 seq 与记录 id。本移植在 `allocateRef` 里先加载（seq 从磁盘最大值续接），避免撞号；
- **系统通知端口**：Dart 侧 `CronNotifier` 已有抽象但无平台实现，本移植只保留端口与文案，不实现具体通知（macOS `UNUserNotificationCenter` / iOS 无此框架，均不实现）；
- **随机 id 后缀**：Dart 用 `dart:math` 随机数，本移植用注入的 `(Int) -> Int` 熵源（测试可确定），形状与唯一性保证不变；
- **本规格不覆盖事件流的 `running` 状态推进**：dsh-cron 事件流语义保留但本端口不主动置位（与 Dart 一致）。

## Swiftus 实现注记

- `CronService` / `CronRegistry` / `CronHistoryBook` / `CronRuntime` 全部 `@ContextTreeActor`；`CronStorage` / `CronNotifier` / 交付端口显式标 `: Sendable`；
- **墙钟一律注入**（`now: @Sendable () -> Date`）与 S19 `TimerDriver` 同款纪律；运行时的 tick 用 `TimerDriver`，测试可手动推进；
- **iOS 上是前台语义（2026-10-10 注记，与 S8 同款）**：3s/15s 的 tick 是进程内定时器，挂起期间不跑，**挂起期间不会准点触发**；恢复前台后下一次 tick 采样墙钟，过期时段按 §5 的 missed-slot 语义补发（daily「整天错过仍补发一次」由 fixtures 钉住）。本域不接入 BGTaskScheduler / 本地通知——需要后台准时性的宿主应自建系统级调度，触发时再调用 cron 的到期判定纯函数（§5 可脱离运行时单独调用）；
- **cron 表达式引擎是纯函数**，可直接用「已知表达式 → 已知触发时刻」的对拍表验证（Dart 侧 `cron_parse_test.dart` 有同款断言，导出成 fixtures）；
- 内部缓存（解析结果 / 下一分钟）用 `class` 内的可变字段承载（`CronTask` 是类不是 struct，否则每次改都要回写表）；
- **「今日这一格已消费」的 daily 语义**（§5）是 missed-slot 补发的关键，fixtures 必须覆盖「整天错过仍补发一次」与「已消费不再补发」两条；
- 交付端口在 Swift 侧为 `@ContextTreeActor (recordId, framing, task) async throws -> Bool`（与运行时同隔离域，故能拿到活的 `CronTask` 而不必把它标成 Sendable；`throws` 对应来源里 `await deliver(...)` 的 try/catch），投递目标由宿主注入（绑定会话时投进该会话，否则投进调用方上下文）；
- **生成的 id 不进 fixtures**（含毫秒与随机后缀），fixtures 只断言 id 形状与唯一性；
- 持久化用 S18 的文件后端（沙盒内 Application Support），原子写复用 `LocalFileSystem.writeAtomic`（临时文件 + 替换目标；**`moveItem` 在目标已存在时会失败**，只写一次的文件看起来正常、第二次以后全丢——本项目在 cron 存储上踩过一次，已把发布器改成 `replaceItemAt` 优先并公开复用）；
- **星期换算是减一不是取模**：Foundation `Calendar.weekday` 是 1=周日…7=周六，cron 约定是 0=周日…6=周六；来源的 `date.weekday % 7` 用的是 1=周一…7=周日的编号，结论等价于这里的减一——照抄取模会把周日算成 1、周五算成 6；
- **工具结果文本按「键排序」的规范 JSON 比对**：Swift 侧 `JSONValue.jsonData()` 走 `JSONSerialization(.sortedKeys)`，而 Dart 的 `jsonEncode` 保插入序，故导出器侧有 `_canonicalJson`（递归按字典序编码）供文本比对使用；
- **JSON 顶层标量不能走 `JSONSerialization`**（会抛 ObjC 异常，Swift 接不住、测试进程直接崩）：JSONL 历史直接拼字节写，单个字符串的 JSON 转义自己实现（`cronJsonStringLiteral`，转义规则与 `jsonEncode` 一致）；
- **时区也注入**（`CronService(timeZone:)`，缺省 `TimeZone.current`）：fixtures 钉 UTC，生产用当前时区。与之配套，导出器自检 `TZ=UTC`（见 `tool/export_fixtures/README.md`）；
- **用例自带输入**（含 CRUD 操作表与运行时场景表）：有状态场景的「操作序列」也进 fixture，Swift 侧按同一张表驱动，避免两端各抄一份脚本；
- **每个 fixture 运行器结尾断言「至少比对过一次」**：参数化用例在一条都没跑到时表现为全绿，空跑的 fixture 比没有 fixture 更危险。
