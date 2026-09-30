# S11 · MCP 客户端

版本：v1.0 · 日期：2026-09-30 · 来源：conatus_mcp（16 个源文件：`mcp_types` / `mcp_json` / `mcp_protocol` / `mcp_protocol_tool` / `mcp_protocol_content` / `mcp_sse` / `mcp_transport` / `mcp_transport_base` / `mcp_transport_stdio` / `mcp_transport_http` / `mcp_transport_sse` / `mcp_client` / `mcp_client_pending` / `mcp_tool` / `mcp_registry` / `mcp`）

语言中立规格。Swiftus 实现注记见文末。
前置：S1（可逆效应）、S4（会话事件）、S5（工具管线）、S12（凭据：`${KEY}` 占位符的唯一来源）。

范围说明：把「连外部 MCP server、把它们的工具接进本地工具表」这套语义忠实搬过来。**本包不含遥测依赖**：断连只通过两个流表达（诊断、断连信号），上层据此注销该 server 的工具。

## 1. 词汇与常量

- 传输类型：`stdio` / `http` / `sse`；
- server 名：既做**工具名前缀**（`server__tool`，双下划线避开本地工具），也做注册表的键；
- 本客户端在 `initialize` 里声明的协议版本 `2025-06-18`（**服务端回不同版本时只记录不拒绝**）；
- 错误：稳定机器码 + 人可读消息。常见码——`timeout`（单次请求超时）、`disconnected`（连接中断，待办全败）、`closed`（客户端已关闭）、`protocol-error`（响应带 error 对象）、`malformed-result`（响应缺 result 对象）、`too-many-pages`（`tools/list` 翻页超限）、`http-status`（HTTP 非 200）、`server-exited`（stdio 子进程退出）、`not-connected`（stdio 未连接就发）、`sse-error` / `sse-closed`（SSE 长连接故障 / 结束）；
- `tools/list` 的**翻页上限 20 页**（防服务端异常导致死循环）；
- 单次请求超时缺省 **30 秒**，**零表示不限时**；
- 风险等级：本地三级 `low` / `medium` / `high`（S5 语义），映射见 §6。

## 2. server 配置（构造期即校验）

`McpServerConfig` 字段：`name` / `type` / `command?` / `args[]` / `env{}` / `url?` / `headers{}`。

- `name` **非空**；
- `type = stdio` → `command` 非空（空串视为缺）；
- `type = http` / `sse` → `url` 非空（空串视为缺）；
- 不合规**装配时即失败**（构造抛错），胜于连接时才失败；
- `env` / `headers` 的值可写 `${KEY}` 凭据占位符，装配时解析（§7）；
- **复制并覆盖**只能覆盖成非空值（不能把 `command` / `url` 改回空缺）。

## 3. JSON-RPC 2.0 词汇

- **解析助手一律「收窄失败即退回缺省」**：解析 JSON 失败返回空、非对象返回空、非字符串返回空、非整数返回空、非列表返回空列表——**不抛错、不中断整条消息**（线协议字段宽松，服务端形态各异）；
- **错误对象**：整数 `code`（缺失退 0）、字符串 `message`（缺失退空串）、可选 `data`；序列化时 `data` 为空**省略键**；
- **消息信封**（请求 / 通知 / 响应三态合一），三态由字段组合判定：
  - `method` 与 `id` 俱全 → **请求**（期待响应）；
  - 只有 `method`（无 `id`）→ **通知**（单向，不期待回复）；
  - 没有 `method` → **响应**；
  - 序列化固定带 `jsonrpc: "2.0"`；`method` / `params` / `id` / `error` 为空则省略；**响应且无 `error` 时写出 `result`**；
- **握手结果**：标准形态 `{protocolVersion, capabilities, serverInfo: {name, version}}`，也接受把 `name` / `version` 直接放顶层的**宽容形态**；`protocolVersion` 缺失退本客户端声明的版本；`instructions` 与 `capabilities` 可选。

## 4. SSE 解析（纯函数，不依赖 MCP）

把字节流解析成 SSE 事件流（跨 chunk 累积）：

- 累积 `event` / `data` / `id` 三个字段，**遇空行派发**一个事件；
- `:` 开头的行是注释，**忽略**；
- 多行 `data` 用 `\n` 拼接；
- 字段值的取法：冒号后**恰好一个前导空格被剥掉**，其余保留；**无冒号视为空值**；
- `data` 为空的块**不派发**（但会清空已累积的字段）；
- **流结束时若还有未派发的 `data`，再派发一次**；
- 事件之间字段不复用（派发后清空）。

## 5. 传输抽象

一条连接的传输层负责：建立 / 断开（**幂等**）、把消息搬到对端、把对端数据还原成消息，外加一条**诊断**流（stderr、坏行、状态变化）。两种错误的归宿必须分清：

- **连接级故障**（进程退出、SSE 结束）→ 送到**消息流**上，上层据此判定断连；
- **单次发送失败**（HTTP 非 200）→ **抛出**，不污染消息流（一次 HTTP 失败不该判定整条会话断连）。

附加约定：

- **传输实例是一次性的**：`disconnect` 之后 `connected` 复位为假，**不再支持重连**；
- 关闭时**不等消息流的 `done`**（单订阅流在没人监听时永远收不到 `done`，等它会让 `disconnect` 永久挂起）；需要「消息流已结束」信号的监听方自己等；
- 调用方传入的 HTTP 客户端**不由传输层关闭**。

三个实现：

- **stdio**：MCP server 是**子进程**，stdin / stdout 走**逐行** JSON-RPC。stdout 逐行解析，**解析不了的那一行只写诊断**、不杀连接；stderr **全量**进诊断；子进程退出或管道中断 → 消息流收到 `server-exited` 错误并随即关闭（等待因此不会永久挂起）；未连接就发送 → `not-connected`；环境变量是**宿主环境 + 配置注入**的合并；
- **http**（Streamable HTTP）：`connect` **不发请求**（HTTP 没有需要预先建立的连接，只标记就绪）；`send` 把消息 **POST** 到端点，响应正文既可能是单条 JSON-RPC 响应，也可能是 `text/event-stream` 正文（此时逐事件解析，正文里可能有多条消息）；**服务端主动推送不在此列**；
- **sse**：`connect` 对端点发 `GET`（`Accept: text/event-stream`）建长连接，服务端**先发一个 `event: endpoint` 事件**，其 `data` 是（可能相对的）**POST 地址**；此后的请求 POST 到该地址，**响应（含服务端主动推送）都从长连接上来**；相对地址按长连接端点解析；长连接结束 → `sse-closed`，出错 → `sse-error`。

HTTP 系共用部分：POST 带 `Content-Type: application/json` 与 `Accept: application/json, text/event-stream` 两个 Accept，**非 200 抛 `http-status` 且不当作断连**；GET 建流时非 200 抛 `MCP SSE <code>`；响应正文的解析**解析不了只写诊断**（不打断连接）。

## 6. 客户端

- **请求与响应按自增整数 id 关联**，乱序响应也能对上号；无关消息（通知、服务端主动请求）**忽略**；
- 每个请求带超时计时器，超时以 `timeout` 收场（消息形如「请求 <id> 在 <毫秒>ms 内没有响应」）；**零超时则不计时**；
- **发送失败收敛到该次请求**（不影响其他在账请求）；
- **断连或关闭**时把所有在账请求一次性判失败（消息形如「与服务端 "<server>" 的连接中断：<原因>」，码为 `disconnected` / `closed`）；
- **握手**：先挂消息订阅 → `connect` → 发 `initialize`（带协议版本 / 空能力集 / 客户端信息）→ 记录握手结果 → 标记就绪 → 发 `notifications/initialized` 通知；
- **取响应的 `result` 对象**：响应带 `error` → `protocol-error`（消息形如 `<code>: <message>`）；`result` 不是对象 → `malformed-result`；
- **列出全部工具**：按 `nextCursor` 翻页（游标为空的请求不带 `params`），直到服务端不再给游标；**超过 20 页抛 `too-many-pages`**；
- **调用一个工具**：失败结果由结果的 `isError` 表达，**不抛异常**；
- **关闭**：取消订阅 → 断开传输 → 剩余待办判 `closed`；**幂等**；
- 对外信号：握手结果（握手前为空）、是否就绪（握手完成且连接仍活）、诊断流、**断连流**（传输结束或出错时触发一次）。

## 7. 工具适配（接进 S5 工具表）

- 工具名 `server__tool`；**描述取 `description`，缺省退 `title`，再缺省退工具名**；分组 `mcp:<server>`；
- **入参 schema 由服务端下发、原样透传给模型**；本地 `ParamSpec` 表达不了任意 JSON Schema，故**参数声明留空**（空声明不做校验，多余参数不会被拒）；服务端没给 `inputSchema` 时给一个空对象 schema；
- **风险映射顺序**（先命中先赢）：
  1. **非标准扩展字段** `riskLevel`（服务端自行声明的标签，**大小写不敏感**）：`readonly` / `read` → `low`，`write` / `mutating` → `medium`，`destructive` / `admin` → `high`；未知标签视为没声明；
  2. 标准注解 `annotations.destructiveHint == true` → `high`；
  3. 标准注解 `annotations.readOnlyHint == true` → `low`；
  4. 其余（**含什么都没声明**）→ `medium`——**默认需要审批**：宁可多问一次，也不要让未知的写操作静默执行；
- **调用失败**（传输 / 协议异常）→ 失败结果，码 `MCP_ERROR`、消息即异常消息；
- **结果投影**：内容块拼成人可读文本——`text` 块原样、其他块给占位（`[<mimeType ?? type>]`，例如 `[image/png]`），**空文本块跳过**，块间换行分隔；线协议的 `isError` 为真 → 失败结果（码 `MCP_TOOL_ERROR`，文本既作内容也作错误消息），否则 → 成功结果（结构化结果进 `value`，无结构化结果时为空）；
- **短别名**：给已注册的全名工具登记一个短名，除名字（以及 schema 里的 `name`）外与被代理工具**完全一致**（风险等级、分组、参数、执行体都跟随）；写操作应继续用全名，让调用日志保留 server 归属。

## 8. 注册表与装配

- 注册表按 server 名持有**绑定**（客户端 + 已注册适配器 + 撤销句柄），服务键 `mcp`；
- **装配一台 server**：握手 → 发现工具 → 上账 → 逐个注册进 `ctx.tools` → 订阅其断连。
  - 握手或发现失败：**先断开该客户端再抛**（不留悬空子进程），**且不上账**——server 列表里不会留下半死条目；
  - 同名 server 重复装配 → 失败；
- **断连只注销该 server 的工具**，其余 server 照常可用（MCP 服务端是外部进程，随时可能消失，不能让它拖垮整张工具表）；断连后从 server 列表移除；
- **短别名**：目标工具不存在 → 失败；短名与已有工具撞车由 S5 注册表拒绝；
- **全部关闭**：断开全部连接并注销全部工具；**幂等**；随上下文释放自动执行；
- 工具注册的撤销句柄同时登记在**上下文**上（上下文释放即撤销，幂等）。

**凭据占位符**：`env` / `headers` 里形如 `${KEY}` 的占位符用凭据服务替换（`KEY` 形如 `[A-Za-z0-9_]+`）。**解析不了（无凭据服务 / 键不存在 / 取凭据抛错）时占位符原样保留**——不抛错、不写日志、不打印明文。**解析结果可能含明文凭据，调用方不得把它写进日志、事件、会话记录或任何模型可见的字段。**

## 9. 有意偏离

- **stdio 传输是 macOS 专属**：来源用 `dart:io` 的 `Process` 起子进程，Foundation 的 `Process` 在 iOS 上不可用。整条 stdio 域（传输实现 + 工厂分支）收在 `#if os(macOS)` 里，**iOS 表面不暴露**；iOS 上装配一个 `stdio` server 明确失败并说明原因，而不是编译期就缺符号（与 S18 的 shell 域同款处理）；
- **传输的 HTTP 客户端**由 `package:http` 改为 `URLSession`（注入点为 `URLProtocol` 桩，见 S12 / S15 / S20 先例）；请求构造（方法 / 头 / 体）逐字对齐；
- **历史写入形状**不适用（本规格无持久化）；**广播流语义**改为显式订阅 + 断连回调（见实现注记）；
- **不做 MCP 的 `resources` / `prompts` / `sampling` 能力**：来源也只实现了 `tools` 能力，能力声明原样透传给上层不做解释。

## Swiftus 实现注记

- `McpRegistry` / `McpClient` / 待办表 / 各传输全部 `@ContextTreeActor`；`McpTransport` 协议显式标 `: Sendable`（全局 actor 协议的 existential 不自动 Sendable）；
- **消息流是单订阅的**（与来源同）：`AsyncStream` 天然单消费者，且「第一次访问 continuation」才建立订阅——因此**客户端必须先挂订阅再发第一条请求**（`initialize` 走的就是这条路径），否则会丢响应（本项目在 S17 踩过同款：订阅要同步建立）；
- **断连不用广播流**：用「每个传输一个 `AsyncStream` + 客户端持一个 `(String) -> Void` 回调」的窄接口（`onDisconnect`），避免广播流的两处投时机问题（锁内 `finish` 会同步触发 `onTermination` → 必崩 `OSAllocatedUnfairLock` 不可重入）；
- **`close()` 与断连的竞态要挡住**：`close()` 取消监听会让消息循环自然退出，退出时的「传输已结束」会抢在「客户端已关闭」之前把待办判成 `disconnected`——来源侧取消订阅后 `onDone` 根本不会触发，故那边没这个竞态；`breakOff` 因此额外看 `closed` 标志；
- **SSE 用字节级解析**（不复用 S10 的 `SseFolder`：MCP 只需要 `event` / `data` / `id` 三个字段与「空行派发」这条规则，自带一个状态机更清楚）；**chunk 边界不得假设**：半行、半字段、多字节字符被切断都要能重组（fixtures 逐条覆盖）；
- **待办表的超时用可注入的 `TimerDriver`**（S19 时间缝）：测试手动推进即可断言 `timeout` 码与文案，零真实等待；
- **断连一次性**：`McpClient` 用 `breakReported` 守卫（与来源同），重复的错误 / 结束事件只收敛一次；
- **管道与子进程等待是阻塞调用，必须离开协作线程池**：`FileHandle.availableData` 与 `Process.waitUntilExit` 留在 `Task` 里会占满协作线程，让同进程的 `Task.sleep` / URLSession 回调一起饿死（实测挂死过一次）；两者都放专用队列，再 `Task` 回隔离域；
- **`Tool.schema` 必须是协议要求而不是扩展成员**（见下节「跨域坑」）：否则 `any Tool` 上的成员访问静态派发到扩展那份实现，MCP 适配器的透传覆写被静默忽略，服务端的 `inputSchema` 永远到不了模型；
- fixtures 投影**不含墙钟与时区**（本规格无时间语义），因此导出器**不需要钉 TZ**（与 S9 不同）；请求体按「解码后的 JSON」比对，`jsonrpc: "2.0"` 逐字锁；
- 端点解析：来源的 `Uri.resolveUri`（相对地址按长连接端点解析）用 `URLComponents` 的相对解析对齐，**不逐字比 URL 串**（编码细节是语言相关的，见 S20 §11 同款纪律）。

## 跨域坑：`Tool.schema` 的协议要求与扩展派发（S5 / S11 共同命中）

**现象**：MCP 工具适配器把服务端下发的 `inputSchema` 原样透传给模型（规格 S11 §7），但模型看到的 `parameters` 始终是「按 `params` 生成的空对象 schema」。

**根因**：`schema` 原先只定义在 `Tool` 的**扩展**里（默认实现按 `params` 生成），不是协议**要求**。存在值（`any Tool`）上的成员访问走 witness table，扩展成员被**静态派发**到扩展那份实现——具体类型里的同名覆写根本不参与派发。

**为什么 fixtures 没抓到**：fixture 运行器拿的是具体类型（`McpToolAdapter`），直接调用时静态派发落到覆写上，行为正确；只有经 `ToolRegistry.describe()` 的**存在值**路径才暴露。发现它的是 Demo 端到端（模型看不到 `required`）。

**修法**：把 `schema` 提升为 `Tool` 的协议要求，扩展只提供默认实现。回归用例见 `S11TransportTests.schemaOverrideSurvivesExistential`（断言走注册表投影时 `parameters.required` 仍是服务端那份）。

**一般化的纪律**：**凡是要被具体类型覆写、且调用方拿到的可能是存在值的成员，都必须声明为协议要求**；只在扩展里给默认实现的成员，覆写会被静默忽略。
