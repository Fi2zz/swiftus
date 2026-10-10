# swiftus

[conatus](https://github.com/Fi2zz/conatus)（Dart 实现的「时空可组合性」编程范式：可逆效应 + 反应式共效应）的 Swift 移植版。命名延续 cordis（TS）→ conatus（Dart）→ swiftus（Swift）的拉丁谱系——移植的动机是**摆脱 Dart 运行时单一依赖，让这套范式成为语言中立的资产**。

- 语言 / 工具链：Swift 6（`swift-tools-version: 6.0`），在 **strict concurrency** 语境下开发
- 主消费场景：**iOS app**（macOS 同样支持）——iOS 侧 13 个 target 实测可编译（`xcodebuild -destination 'generic/platform=iOS'`），接入指南见 `docs/ios-接入指南.md`
- 平台下限：macOS 13 / iOS 16
- 外部依赖：**Yams 5.x**（仅 `SwiftusSkill` 用它解析 frontmatter）+ 系统 `CryptoKit`（SigV4 签名）
- 许可：MIT

## 当前状态（2026-10-10，v0.1.6）

**W1 / W2 / W3 全部收口**——12 个 conatus 包、规格 S1–S20、golden fixtures 全部落地。swift-testing **354 例 73 套件 debug + release 双绿**，release 构建零警告，CI 三 job（verify / ios / fixtures）就位，`docs/samples` 的 iOS 样例自检也已编入门禁。

| 波次 | 范围 | 状态 |
|---|---|---|
| W1 | core / credentials 最小集 / llm / prompt / tool / skill + 离线 Demo | ✅ |
| W2 | Compaction / Schedule / session 持久化层 / Agent 全特性 / 任务中心 | ✅ |
| W3 | 凭据全量 + SigV4（S12 v1.1 / S15）、Foundation 全部 14 个能力域（S18 fs+shell、S19 database/timer/time-context/logger/loader） | ✅ |
| W3 余下 | Cron（S9）/ Search（S20）/ MCP（S11） | ✅ |

离线 Demo 跑通「提问 → 工具调用 → 回填 → 收口」，并**逐段演示**会话持久化 / 任务中心 / 提醒 / 定时任务交付 / 联网搜索 / MCP server 工具（脚本化模型 + 进程内 MCP server，**无需任何 Key / 无需网络**）：

```bash
swift run swiftus-demo
```

## 30 秒上手

代码取自 `docs/samples/IosIntegrationSample.swift`（以 iOS SDK 类型检查验证过，非伪代码）；`makeConfig()` / `apiKeysJsonPath` 是宿主侧的端点配置与文件路径，见样例全文：

```swift
import Swiftus

@ContextTreeActor
enum QuickStart {
    /// 装配：上下文树 → 凭据 → 工具 → prompt → LLM。
    static func bootstrap() throws -> Context {
        let app = Context.root(name: "my-app")

        // 凭据：Key 放沙盒文件（{"ARK_API_KEY": "sk-xxx"}），别硬编码进二进制。
        let credentials = FileCredentials(path: apiKeysJsonPath)
        _ = try provideCredentials(app, credentials: credentials)

        // 工具：注册进白名单管线（schema 投影 / 参数校验 / 失败码收敛都在管线里）。
        let tools = try provideTools(app)
        try tools.fn("now", description: "返回当前时刻") { _ in
            .success(ISO8601DateFormatter().string(from: Date()))
        }

        _ = try provideSystemPrompt(app)   // system prompt 装配
        _ = try provideTimePrompt(app)     // 日粒度「今天」注入（跨天自动更新）
        _ = OpenAiCompatibleProvider(config: makeConfig(), credentials: credentials)
        return app
    }

    /// 跑一轮：工具描述 → 调模型 → 执行工具 → 回填 → 收口。
    static func ask(_ app: Context, _ question: String) async throws -> String {
        let tools = try app.require(.tools)
        let prompt = try app.require(.systemPrompt)
        let llm = OpenAiCompatibleProvider(
            config: makeConfig(),
            credentials: try app.require(.credentials)
        )

        var messages: [LlmMessage] = [
            LlmMessage("system", prompt.renderContexts(prompt.assemble())),
            LlmMessage("user", question),
        ]
        for _ in 0..<8 {
            let result = try await llm.chat(LlmRequest(messages: messages, tools: tools.describe()))
            guard !result.toolCalls.isEmpty else { return result.content }
            messages.append(.toolCallRequest(result.toolCalls, content: result.content))
            for call in result.toolCalls {
                let args = (try? JSONValue.parse(Data(call.arguments.utf8)))?.objectValue ?? [:]
                let outcome = await tools.call(ToolCall(name: call.name, callId: call.id, arguments: args))
                messages.append(.toolResult(call.id, outcome.content))
            }
        }
        return "（达到轮次上限）"
    }
}
```

要点：所有 `Context` 成员都是 `@ContextTreeActor` 隔离——SwiftUI 视图模型别直接碰，套一个 `@ContextTreeActor` 的 runtime 盒子，再在 `Task` 里跨 actor 调用（完整 SwiftUI 接线见 `docs/samples/IosIntegrationSample.swift`）。要 Agent Loop（自动多轮 / 规划 / 审批）而不是手写回路，用 `SwiftusAgent` 的 `AgentLoop`；更多域（会话持久化 / 任务中心 / cron / 搜索 / MCP）按「模块地图」取用。

## 模块地图

依赖方向自上而下无环，镜像 conatus 的包结构（以 `Package.swift` 为准）：

| target | 行数 | 依赖 | 职责 |
|---|---|---|---|
| `SwiftusCore` | 649 | —（只 `import Foundation`） | 上下文树 / 可逆效应（LIFO 撤销·幂等·迟到登记）/ Reactor / `ServiceKey` / `JSONValue` / `Redaction` |
| `SwiftusFoundation` | 4,947 | Core | 14 个能力域：tools / session / session-log / system-prompt / memory / database / fs / shell / time-context / timer / logger / loader / ask-user / uuid |
| `SwiftusCredentials` | 1,101 | Core | 五种来源（env / memory / file / vault / aws）+ AWS SigV4 签名链 + 可插拔来源端口（S12 §7.5） |
| `SwiftusLLM` | 925 | Core, Credentials | chat / responses 双形态、流式增量、fallback 链 |
| `SwiftusCompaction` | 554 | Core, Foundation | 压缩切点（平衡切点）算法 |
| `SwiftusSkill` | 1,335 | Core, Foundation, Yams | 技能 frontmatter 解析与目录发现 / 注册表 |
| `SwiftusSchedule` | 1,961 | Core, Foundation | 调度选择器、IANA 时区 / DST 边界 |
| `SwiftusAgent` | 6,294 | Core, Foundation, LLM, Compaction, Schedule | Agent Loop 全特性（规划 / 反思 / 路由 / 子智能体 / 审批 / 恢复 / 目标 / 遥测 / eval） |
| `SwiftusTasks` | 1,109 | Core, Foundation, Agent, Schedule | 任务中心：状态机、工具、shell / schedule 交付追踪 |
| `SwiftusCron` | 2,051 | Core, Foundation | cron 表达式引擎 / 注册表 / 历史账本 / 运行时（3s/15s tick）/ 五工具 / JSON 存储 |
| `SwiftusSearch` | 1,081 | Core, Credentials, Foundation | 4 provider 顺序回退 + 两个抓取后端（web_search / fetch_url） |
| `SwiftusMCP` | 2,052 | Core, Credentials, Foundation | MCP 客户端：stdio / http / sse 传输 + JSON-RPC 2.0 |
| `Swiftus` | 12 | 全部 | 伞产品：仅 `@_exported import` |

### 取用建议

**① 可以整片拿走用（零外部依赖）**——`SwiftusCore` 加 Foundation 的基础设施域（logger / timer / database / loader / fs / shell），约 3,000 行，只依赖系统框架与 Core：上下文树 + 可逆效应、分级日志、可逆定时器与节流防抖、KV 存储、有界输出的命令执行、带守卫的文件系统。`SwiftusCredentials` 亦可整拿（`CryptoKit` 是系统框架）。

**② 有约束**：
- **iOS 上没有 shell**——iOS 无子进程（`Process` 在 iOS SDK 不存在），故整个 shell 领域（词汇、`ShellExecutor` 端口、`shell` 服务键、装配、本地后端，以及 S17 的 shell 追踪装饰器）收在 `#if os(macOS)` 内，**iOS 表面不暴露 shell**（MCP 的 stdio 传输同理只在 macOS）。其余 12 个 target 在 iOS 上原样编译：fs / database / logger / timer / loader / time-context 六域无平台限制（`FileHandle` 在 iOS 可用），Agent / Tasks / LLM / Schedule / Compaction / Skill / Credentials / Cron / Search / MCP（stdio 传输除外）亦然；
- `SwiftusSkill` 是唯一拉第三方包的地方（Yams）。接入方 floor 低于 macOS 13 / iOS 16 需抬；
- 模块级 global actor `@ContextTreeActor`：若被 vendored（拷源码而非依赖），两份 actor 身份不同、跨边界传值会别扭；
- **沙箱语义差异**：fs / database 走宿主磁盘，iOS 上受沙盒约束（Application Support 目录、不可访问任意路径），与 macOS 的行为面不同——这是平台本身的差异，不是实现问题。

**③ 建议整套搬**：`SwiftusAgent` / `SwiftusLLM` / `SwiftusCompaction` / `SwiftusSchedule` / `SwiftusTasks` 是建在上下文树与工具 / 装配管线之上的完整栈，抽单个文件得到的是演示而非能力。

## 规格先行

移植的四条铁律：**规格先行**（不逐行翻译 Dart，每个领域动工前先产出语言中立规格）、**共享 golden fixtures**（不逐条翻译 Dart 侧约 1600 个测试，而是导出行为级 fixtures 两端共用）、**Swift 惯用法 API**（形状允许偏离，语义不偏离）、**conatus 只读**（发现 Dart 侧缺陷只在 Swift 侧修正，并登记为规格的「有意偏离」条目）。

`spec/` 下 **20 份**语言中立规格（S1–S20）：

| | | | |
|---|---|---|---|
| S1 效应语义 | S2 上下文树 | S3 session 事件格式 | S4 session-log |
| S5 工具管线 | S6 prompt 装配 | S7 压缩切点 | S8 调度语义 |
| S9 Cron 定时任务 | S10 LLM 协议 | S11 MCP 客户端 | S12 凭据 |
| S13 memory 召回 | S14 skill catalog | S15 SigV4 签名链 | S16 Agent Loop 产品化 |
| S17 任务中心 | S18 Foundation 能力域（fs / shell） | S19 Foundation 能力域（database / timer / time-context / logger / loader） | S20 联网搜索与抓取 |

**规格这一层本身也可以复用**：它是语言中立的，两端跑同一批用例对答案——目标项目若要自己重写一套，这批规格与 fixtures 可以直接当验收基线，不必重译 Dart 测试。

## Golden fixtures

`spec/fixtures/` 下 **13 个领域**（s4 / s7 / s8 / s9 / s11 / s12 / s13 / s15 / s16 / s17 / s18 / s19 / s20）的行为级用例，全部由本仓 `tool/export_fixtures/` 的 Dart 导出器在本地 conatus checkout 上**导出并校验**（不是手写）。归一化规则（时间不入 fixture、id 归一、事件循环时机不进断言等）见 `tool/export_fixtures/README.md`。

```bash
# 重新导出全部 fixtures（需同级目录有 conatus checkout，且已 dart pub get）
bash tool/export_fixtures/export.sh
```

## 验证

```bash
bash tool/ci/verify.sh     # 门禁①：debug/release 零警告 + 测试各双跑 + Demo 冒烟
bash tool/ci/ios.sh        # 门禁②：iOS 13 target 编译 + 符号表核验 + 样例自检
bash tool/ci/fixtures.sh   # 门禁③：从 CONATUS_PIN 重跑导出器并 diff（需 conatus）

swift build && swift test                          # 单步调试用
swift run swiftus-demo                             # 离线端到端 Demo
```

波次出口门槛：fixtures 全绿 + swift-testing 覆盖语义关键点 + `swift build -c release` 零警告。CI 三个 job 调的就是上面三个脚本（`.github/workflows/ci.yml`），**本地与 CI 跑同一份命令**。

## 文档

- `docs/ios-接入指南.md`——**iOS 接入**：加依赖方式、选哪个 product、可编译样例、必踩的坑（`@ContextTreeActor` 隔离 / 凭据别硬编码 / iOS 无 shell / Schedule·Cron 前台语义；原「`Task` 遮蔽」已根治，任务值类型改名 `SwiftusTask`）、平台能力对照、样例自检命令
- `AGENTS.md`——项目状态、仓库布局、执行顺序、测试策略、已定稿的设计决策、已知坑清单（面向 AI 编码代理与新成员）
- `spec/S*.md`——各领域语言中立规格（含「有意偏离」条目与实现注记）
- `HANDOFF.md`——跨会话交接：现状 / 已完成 / 下一步 / 验证命令 / 已采的坑（**本地文件，不在版本管理内**，见文件头说明）
- `tool/export_fixtures/README.md`——fixtures 导出与归一化规则

> `docs/.handoffs/` 下的两份权威文档（移植方案书 v1.2 / 可行性评估报告 v2.3）与 `HANDOFF.md` **按约定只留本地、不入库**（`.gitignore` 已显式记录），因此工作区里可能找不到它们；文档中引用「方案书 §x」处，在本机没有该文件时按 `AGENTS.md` + `spec/` 的「有意偏离」条目执行。
