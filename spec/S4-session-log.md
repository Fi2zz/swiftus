# S4 · Session Log

版本：v1.1 · 日期：2026-09-28 · 来源：conatus_foundation `session_store.dart` / `session_persistence.dart` / `session_log*.dart` / `conatus_home.dart` / `uuid.dart`；v1.1 增补来源：conatus_agent `agent_types.dart` / `model_visible_invariant.dart` / `session_log_integration.dart` / `session_log_llm.dart`
语言中立规格。Swiftus 实现注记见文末。
前置：S3（Session 事件格式与内存态会话）。
范围说明：本版覆盖持久化端口、SessionStore、SessionLog 三后端（内存 / JSONL 持久化；Database 后端随 database 能力域后补）；v1.1 增补派生事件与「模型可见即已记录」不变式（随 Agent Loop 核心刀落地）。

## 1. 持久化端口（SessionPersistence）

四个动作，更换后端（数据库 / 对象存储）时消费方代码不变：

| 动作 | 语义 |
|---|---|
| `list() -> [String]` | 已持久化的会话 id（升序） |
| `load(id) -> [SessionEvent]` | 载入某会话全部事件；不存在返回空列表 |
| `append(id, event)` | 追加一条事件（append-only，O(1) 行写入） |
| `remove(id)` | 删除某会话的全部持久化数据 |

### 1.1 JSONL 实现（JsonlSessionPersistence）

- 一会话一文件：`<dir>/<sessionId>.jsonl`；缺省目录 `<数据根>/sessions`（§5）；
- 每行一条事件的 JSON（S3 §4.1 形状，含递归脱敏）；append 模式写入 + flush；
- 写入前父目录递归创建；
- 载入逐行解析：**空行跳过**；一行不是 JSON 对象则跳过（宽容，损坏行不拖垮整份日志）；
- `list()` 只收 `.jsonl` 后缀文件、去后缀得名、排序；`remove` 幂等（不存在不报错）。

## 2. SessionStore（`'sessions'` 服务）

进程内持有活跃会话，并可选地接线持久化。

### 2.1 生命周期

- `create({id})`：新会话；id 缺省 `session_<uuid v4>`；同 id 已活跃抛错（StateError 级）；
- `adopt(session)`：注册外部创建的会话（如 fork 产物）；同 id 已活跃抛错。接有持久化时**先把全部种子事件落盘**（fork 的继承历史不能在重开时丢失），再接后续追加；
- `open(id)`：已活跃直接返回；否则从持久化载入事件作为种子（无持久化时空会话）。载入事件**不会重复落盘**（种子不触发追加接线）；
- `close(id)`：关闭并从活跃表移除，返回是否确实移除；
- `remove(id)`：close + 删除持久化数据；返回是否有东西被处理（closed || 有持久化）；
- `persistedIds()`：已持久化会话 id（未接持久化时空表）。

### 2.2 写入接线与 flush

- 接线（`_attach`）：接有持久化时挂 `onEvent`——每条追加事件异步入链落盘；挂 `onClose`——关闭时从活跃表移除；
- **写入链串行化**：同一进程内的落盘写入串行执行（前一次落定后下一次才开始），避免并发写同一文件丢事件；链上吞错只为不卡住后续写入，**原始写入错误保留**，由 flush 暴露；
- `flush()`：等待所有在途写入落定；任一在途写入失败 → flush 抛错（首个失败）。

## 3. SessionLog（多会话只追加日志，`'sessionLog'` 服务）

Session 是单会话内存日志；SessionLog 面向多会话：按 sessionId 归档、按时间窗读取、从任意事件点分叉历史、重放。**只追加是硬不变式**：日志永不改写，fork 只产生新会话，源会话不受影响。

| 成员 | 语义 |
|---|---|
| `append(event) -> SessionEvent` | 事件必须带非空 sessionId（否则快速失败）；**seq 由日志按会话分配**（每会话从 0 起密集递增，等于追加序号），入参自带 seq 被覆盖；事件 id 原样保留；返回落定后的事件 |
| `read(sessionId, {from, to})` | 按 seq 顺序读取；from/to 为 time 闭区间过滤 |
| `fork(sessionId, fromEventId, {newId}) -> String` | 取「截止该事件（含）」的前缀，**重盖章**（新 sessionId、seq 从 0 重排；事件 id 与 parentEventId 原样保留）后整段写入新会话；fromEventId 不存在抛错（StateError 级）；新 id 缺省 `<sessionId>-fork-<n>`（n 按源会话计数） |
| `replay(sessionId, handler)` | 按 seq 顺序逐条回调；日志不被改写 |
| `list() -> [String]` | 全部会话 id 升序 |
| `close()` | 释放后端资源；幂等 |

### 3.1 InMemorySessionLog

进程内 Map 后端：适合测试与短生命周期进程，进程退出即丢失。close 后清空全部状态。

### 3.2 PersistenceSessionLog（追加式，长会话推荐）

复用 SessionPersistence：append 先分配 seq（**首次使用时从已落盘事件数续接**，进程内缓存计数）再落盘；fork 逐条重写前缀到新会话文件；read/replay 经 load；close 无操作（端口自有生命周期）。

### 3.3 装配优先级（provideSessionLog）

显式 `log` → `persistence`（或 `'sessionPersistence'` 服务）→ database（W3 后补）→ 进程内 InMemorySessionLog。上下文释放时关闭日志（异步 close 登记为同步触发 + 不等待）。

## 4. SessionStore ↔ SessionLog 分工

SessionStore 管「活跃会话的内存态 + 写接线」；SessionLog 管「多会话日志的读与派生」。两者可独立装配；SessionSchedule 的持久化检查点缝（S8 §11.1）由 SessionStore.flush 适配：`flush: { try await store.flush() }`。

## 5. 家目录与 UUID

- 数据根解析：`<环境变量覆盖>` 优先，否则 `<用户目录>/.conatus`；解析不到用户目录（无 HOME / USERPROFILE）快速失败（StateError 级），**绝不在当前工作目录兜底**；
- 会话 id 缺省：`session_<uuid v4>`（小写十六进制 8-4-4-4-12）。

## 6. 派生事件与「模型可见即已记录」（v1.1 增补）

### 6.1 派生事件（非模型可见）

业务 `Session` 是**模型可见的唯一真相源**；SessionLog 是它的**超集**——镜像全部业务事件，再追加派生事件。`deriveAgentMessages` 只认三类消息事件（S3 §2），派生事件不污染请求派生：

| 事件 | 载荷 | 时机 |
|---|---|---|
| `llm/request` | `{provider, messages: [消息 toJson 形状], tools?}`（tools 仅非空时落键） | 真正发送给模型**之前** |
| `llm/response` | `{provider, model, content, toolCalls, usage}`；流式追加 `finishReason` | 收到响应后 |
| `tool/call` | `{name, callId, group, args}` | 工具执行**之前**（中间件）；工具结果不重复记录（业务 `tool/result` 已镜像） |

派生事件的 `parentEventId` 指向已记录的最后一条事件，整个会话在日志里是一条因果链；业务事件自带 parentEventId 时保留（业务因果优先）。

### 6.2 「模型可见即已记录」不变式（checkModelVisibleInvariant）

凡进入模型的内容都能在日志里找到出处，不存在绕过日志的上下文注入：

- 对日志中每条 `llm/request`：用 deriveAgentMessages 从**该事件之前**的事件重建会话消息；请求载荷的会话部分（**跳过开头连续的 system 消息**）必须是可重建消息的**尾对齐后缀**，且逐条递归全等（压缩只会让窗口变短，故后缀对齐）；
- 违规文案：`第 N 条 llm/request 缺少 messages 负载` / `第 N 条 llm/request 实际发出 M 条会话消息，日志只能重建 K 条` / `第 N 条 llm/request 的第 i 条会话消息无法从日志重建`；
- **不在校验范围**：压缩摘要请求（会话部分仅一条 user 且含 `kCompactionSummaryPrompt` 前缀——它把早前事件转写成一段文本，不是对话窗口）；system prompt（由运行时状态现场装配）；
- `assertModelVisibleInvariant`：违规非空抛错（`模型可见即已记录不变式被破坏：\n<违规逐行>`），开发模式用。

### 6.3 记录器与装饰器

- `SessionLogRecorder(log, strictModelVisible: false)`：`attach(session)` 先补记存量（replay）再订阅追加，返回幂等撤销；重复 attach 先撤销上一次；`record(type, data)` 记派生事件（未 attach 静默忽略）；**写入串行化**（追加顺序在多路调用下稳定）；
- `SessionLogLlmProvider(inner, recorder)`：LlmProvider 装饰器——chat / chatStream 两侧记录，不改动请求本身；`strictModelVisible` 开启时**发送前**校验不变式（每次回读日志，O(n)，生产关闭）；
- `instrumentSessionLogTools(tools, recorder)`：注册中间件记录 `tool/call`；
- 装配：`provideSessionLogRecorder`（服务键 `sessionLogRecorder`；依赖 `sessionLog`，缺则自动补）；`provideAgentLoop` 在 recorder 与 session 齐备时接线 `attach` + 工具埋点（随上下文释放撤销）。

## 7. 有意偏离

（无。）

## Swiftus 实现注记

- `SessionPersistence` 协议为非隔离 async（落盘 IO 不占用 ContextTreeActor）；`SessionStore` / 两后端为 `@ContextTreeActor`（内存态一致性），await 段自然让出；
- **镜像写入的入链顺序**：Dart 的 `unawaited(_mirror(event))` 经 `_serialize` **同步入链**（Future 链头立即推进），因此业务镜像恒早于随后 await 入链的 `llm/request`；Swift 侧 SessionLogRecorder 的 mirror 同样必须同步推进链尾（`enqueueAppend` 返回 Task 而非 async 函数），包外层 `Task { … }` 会让 llm/request 抢到镜像前面（S4 fixtures 的 agent-loop 用例抓到）；
- 写入链：actor 域内 `Task` 链（新写入在前一个 Task 落定后启动；链上吞错不卡后续，错误由 flush 收集重抛——对齐「原始错误保留供 flush 暴露」）；
- JSONL 行：事件 `jsonValue`（S3 §4.1，含脱敏）→ JSONSerialization 落笔；载入逐行 `JSONValue.parse` + `SessionEvent(jsonValue:)` 宽容解析（S3 §4.2）；
- 家目录常量更名：`SWIFTUS_HOME` 环境变量 + `~/.swiftus`（产品身份迁移；解析语义不变）。`newUuidV4` 用 Foundation `UUID().uuidString.lowercased()`（同为 v4 形状）；
- `read` 的 Dart Stream 在 Swift 侧为 `[SessionEvent]` 数组返回（内存量可控，语义等价；调用方无流式增量需求）；
- DatabaseSessionLog 不在本轮（database 能力域属 W3），装配优先级链保留 database 档位注释占位。
