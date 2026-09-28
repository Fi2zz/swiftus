# S3 · Session 事件格式

版本：v1.0 · 日期：2026-09-27 · 来源：conatus_foundation `session.dart` / `session_types.dart`；脱敏规则来自 conatus_core `redaction.dart`
语言中立规格。Swiftus 实现注记见文末。
变更：v0.1 仅脱敏一节（脱敏实现落在 core，先行沉淀）；v1.0 补全事件格式与会话日志主体（随 compaction 动工）。

## 1. 事件（SessionEvent）

会话日志中的一条事件，字段全集：

| 字段 | 类型 | 说明 |
|---|---|---|
| `seq` | int | 日志内的稳定位置，由所属会话在追加时分配（§3），从 0 起单调递增 |
| `type` | string | 事件类型（如 `user/message` / `tool/result`），开放词汇 |
| `time` | 时间戳 | 事件发生时间；追加时可注入，缺省取当前时刻 |
| `data` | 动态 JSON 或 null | 可 JSON 序列化的负载 |
| `id` | string 或 null | 事件唯一标识，用于跨会话引用与 fork；缺省时追加方生成（§1.1）；旧数据可能为 null |
| `sessionId` | string 或 null | 归属会话 id；由 `Session.append` / SessionLog 写入时补齐 |
| `parentEventId` | string 或 null | 触发本事件的父事件 id，用于因果追踪（如工具结果指向发起它的助手消息） |

### 1.1 事件 id 生成

`evt-<微秒级 Unix 时间戳>-<进程内单调序号>`；进程内单调、跨会话唯一（时间戳同微秒时由序号兜底）。

## 2. 消息事件类型常量

| 常量 | 值 | 说明 |
|---|---|---|
| `kUserMessageEvent` | `user/message` | 用户消息 |
| `kAssistantMessageEvent` | `assistant/message` | 助手消息（可携带 `data.toolCalls` 数组，压缩切点安全以此计数，见 S7 §5） |
| `kToolResultEvent` | `tool/result` | 工具结果 |

事件类型是开放词汇：以上仅为消息类常量，其余领域（如 S7 的 `compaction/*`）各自登记。

## 3. 会话（Session）：append-only 日志

一条会话是一串不可修改的事件。日志**只追加、不改写**；任何派生都是新事件 / 新会话。

### 3.1 构造与 seq 分配

- 空会话从 `seq = 0` 开始；带 `seed` 构造时从末条 seed 事件的 `seq + 1` 续接；
- `inheritedEventCount` 表示 seed 中继承自父会话的事件条数（fork 时大于 0，重新打开会话时为 0），必须落在 seed 范围内（`0...seed.count`），否则构造快速失败；
- `createdAt` 取首条事件时间；空日志为构造时刻。

### 3.2 追加

- `append(type, {data, parentEventId, time, id})`：分配下一个 seq，生成事件（缺省 id 走 §1.1，缺省 time 取当前时刻，补齐 sessionId），入日志并同步通知 `onEvent` 监听器；返回落定的事件；
- `appendEvent(event)`：追加一条已构造的事件；事件被**重新盖章**——sessionId 换成本会话 id、seq 换成本会话下一个 seq、id 缺省重新生成，**time 保留原值**；返回落定后的事件。这使 SessionLog / 反序列化路径可以安全回填；
- 会话关闭后两种追加都抛错（StateError 级）。

### 3.3 读取

- `events`：全量只读视图（不可修改副本）；
- `ownEvents`：跳过继承前缀、本会话真正拥有的事件；
- `length` / `closed` / `lastEventId`（空日志为 null）；
- `read(from:, to:)`：按 `time` 闭区间过滤（`from <= time <= to`），nil 端不限。

### 3.4 监听

- `onEvent(listener)`：监听后续追加（seed 与追加前的存量不补播）；返回幂等撤销函数；
- `onClose(listener)`：监听关闭；**已关闭时立即回调**；返回幂等撤销函数；
- 监听器逐个同步调用；广播基于监听器列表快照，广播期间增删不影响当次。

### 3.5 关闭

`close()`：置关闭标志 → 基于快照通知全部 onClose 监听器 → 清空两类监听器 → 拒绝后续追加。幂等。

### 3.6 fork

`fork({fromEventId, id})`：从某个事件点分叉出新会话——

- 种子为「截止该事件（含）」的日志前缀；`fromEventId` 缺省时以全量日志为种子；
- 找不到该事件 id 时抛错（StateError 级）；
- 新会话 id 缺省为 `<原 id>-fork-<n>`，n 为原会话的 fork 累计次数（从 1 起）；
- 新会话 `inheritedEventCount` = 种子条数，即全部种子都是继承前缀；
- 原会话完全不受影响；新会话与原会话解耦（各自追加互不可见）；
- 派生状态只折叠自身后缀（ownEvents），因此 fork 出的会话不继承父会话的活动状态（如进行中的提醒，见 S8）。

### 3.7 replay

`replay(handler)`：按日志顺序对每条事件同步回调一次；日志不被改写。回放基于事件列表快照。

## 4. JSON 序列化

### 4.1 toJson

```
{seq, type, time: ISO8601 字符串, data?: 递归脱敏后的负载, id?, sessionId?, parentEventId?}
```

- `data` 为 null 时整个 `data` 键不输出；`id` / `sessionId` / `parentEventId` 为 null 时对应键不输出；
- 负载中的凭据字段按 §5–§7 递归脱敏后落笔——**日志序列化永不写明文凭据**。

### 4.2 fromJson（宽容解析）

- `seq` 缺省 0、`type` 缺省空串；
- `time` 解析失败（缺键或非 ISO8601）时退回**当前时刻**（注意：这是非确定点，重放同一份 JSON 会得到不同 time；比对语义时不以 time 为准）；
- `data` / `id` / `sessionId` / `parentEventId` 缺键为 null；
- fromJson 是数据搬进内存的入口，**不回填脱敏**（脱敏只发生在 toJson 落笔方向）。

## 5. 敏感键判定（isSensitiveKey）

键名命中任一规则即视为凭据字段，大小写不敏感，兼容下划线 / 连字符 / 驼峰：

- **规范化命中**：键名转小写并剔除非 `[a-z0-9]` 字符后，命中敏感词元表；
- **分段命中**：键名按非字母数字切分，任一段命中敏感词元表（如 `ARK_API_KEY` → `ark` + `api` + `key`）。

敏感词元表：`key` / `apikey` / `token` / `secret` / `password` / `passwd` / `authorization` / `credential` / `credentials` / `privatekey` / `accesskey` / `secretkey`。

- 简单复数视同命中：词元加尾 `s`（`keys` / `tokens` / `secrets` …）。
- 规范化后为空串：不敏感。

## 6. 脱敏表示（maskSecret）

- 空串 → 空串；
- 长度 ≤ 8 → 等长全星号（短密钥不做局部保留，避免近乎完整暴露）；
- 长度 > 8 → 前 4 位 + `...` + 后 4 位。
- 「长度」与「取位」按 UTF-16 码元计（与 Dart `String.length` 对齐；ASCII 凭据无差异）。

## 7. 递归脱敏（redactSecrets）

- 输入为动态 JSON（object / array / string / number / bool / null），**不修改入参**，返回新值；
- object：值递归脱敏；键名命中敏感键时，其值改为遮蔽表示——字符串值走 `maskSecret`，非字符串非 null 值（数字、对象等）替换为 `***`，null 保持 null；
- array：逐元素递归；
- 其余标量：原样返回。

## 8. 有意偏离

| Dart 行为 | Swift 修正语义 | 理由 |
|---|---|---|
| `Session.fork` 找不到 `fromEventId` 时，错误消息中的会话 id 取自 fork 的新会话 id 参数（常为 null，消息显示「会话 "null" 中不存在事件 …」）——`session.dart` 中参数 `String? id` 遮蔽了 `this.id` | 错误（`SessionError.eventNotFound`）中的会话 id 恒为**原会话** id | 诊断信息应指向持有日志的原会话；Dart 侧明显笔误。待上游修复后对齐并移除本条目 |

## Swiftus 实现注记

- 动态 JSON 载体为 `JSONValue` 枚举（方案书 §5.2），`redactSecrets(JSONValue) -> JSONValue` 在 SwiftusCore；
- `SessionEvent` 为 Sendable struct，`data: JSONValue?`；`Session` 为 `@ContextTreeActor final class`（整树单 actor 惯例，与 ToolRegistry 一致），StateError / ArgumentError 级错误对应结构化 `SessionError`；
- 事件 id / 时间戳生成器放 actor 域内，保证进程内单调；测试经 `append(..., time:)` 注入固定时间戳获得确定性；
- `time` 序列化统一输出 UTC 带 `Z` 的 ISO8601（含小数秒；Dart `toIso8601String` 对本地时间不带 `Z`）；`init(jsonValue:)` 宽容解析（§4.2）为跨端交换兜底。
