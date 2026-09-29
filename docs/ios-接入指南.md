# iOS 接入指南

版本对应：**v0.1.0**（W2 收口 + W3 的凭据全量 / SigV4 / Foundation 14 域 + iOS 可编译性）
本文里的代码样例**以 iOS SDK 类型检查验证过**（不是伪代码），验证命令见文末。

## 1. 前置条件

| 项 | 要求 |
|---|---|
| 部署目标 | **iOS 16.0+**（包声明的 floor；低于此 Xcode 拒绝解析） |
| Swift | 6（`swift-tools-version: 6.0`，strict concurrency） |
| 平台限制 | 9 个库 target 与伞产品在 iOS 上均已实测编译通过 |

## 2. 添加依赖

Xcode → File → **Add Package Dependencies…** → 输入：

```
https://github.com/Fi2zz/swiftus.git
```

版本规则选 **Up to Next Major**（或 Exact / Range），填 `0.1.0`（tag 为 `v0.1.0`，SwiftPM 两种写法都认）。

### 2.1 选哪个 product

Xcode 的 Target → General → Frameworks, Libraries → **Add Package Product**，按需选：

- **`Swiftus`（伞产品）**——一个产品拿到全部模块，最省事；**代价是它包含 `SwiftusSkill`，会连带引入第三方依赖 Yams 及其 C 模块 CYaml**。
- **按需选**（不想引入任何第三方依赖时选这套）：`SwiftusCore`、`SwiftusFoundation`、`SwiftusCredentials`、`SwiftusLLM`；要 Agent 能力再加 `SwiftusCompaction` + `SwiftusSchedule` + `SwiftusAgent`（Agent 依赖这三者）；要任务中心再加 `SwiftusTasks`；要技能目录才加 `SwiftusSkill`（**只有它会拉 Yams**）。

依赖关系：`Agent → {Core, Foundation, LLM, Compaction, Schedule}`；`Tasks → {Core, Foundation, Agent, Schedule}`。不要选 `SwiftusCron` / `SwiftusSearch` / `SwiftusMCP`——**这三个 target 目前是空声明，尚无实现**。

## 3. 最小可跑样例

完整可编译版本见 [`docs/samples/IosIntegrationSample.swift`](samples/IosIntegrationSample.swift)。要点：

```swift
import Swiftus                       // 伞产品（会 re-export SwiftusTasks，见坑 ①）

@ContextTreeActor
enum Bootstrap {
    static func make() throws -> Context {
        let app = Context.root(name: "ios-app")

        // 1) 凭据：Key 放沙盒文件，别硬编码进二进制
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let credentials = FileCredentials(
            path: support.appending(path: "api-keys.json").path
        )                                        // 文件内容：{"ARK_API_KEY": "sk-xxx"}
        _ = try provideCredentials(app, credentials: credentials)

        // 2) 工具：ParamSpec 白名单投影 + 参数校验 + 失败码收敛
        let tools = try provideTools(app)
        try tools.fn("now", description: "返回当前时刻") { _ in
            .success(ISO8601DateFormatter().string(from: Date()))
        }

        // 3) 日粒度「今天」注入 system prompt（跨天自动更新）
        _ = try provideSystemPrompt(app)
        _ = try provideTimePrompt(app)

        // 4) LLM：OpenAI 兼容 wire 层，按凭据键取 Key，凭据变更自动就地轮换
        var config = OpenAiConfig(name: "ark",
                                  baseUrl: "https://ark.cn-beijing.volces.com/api/v3",
                                  model: "doubao-seed-1-6")
        config.credentialKey = "ARK_API_KEY"
        _ = OpenAiCompatibleProvider(config: config, credentials: credentials)

        return app                              // 整条链随上下文释放：凭据 close、LLM 退订
    }
}
```

跑一轮（工具描述 → 调模型 → 执行工具 → 回填 → 收口）：

```swift
static func ask(_ app: Context, _ question: String) async throws -> String {
    let tools  = try app.require(.tools)
    let prompt = try app.require(.systemPrompt)
    let llm = OpenAiCompatibleProvider(config: config, credentials: try app.require(.credentials))
    let system = prompt.renderContexts(prompt.assemble())

    var messages: [LlmMessage] = [LlmMessage("system", system), LlmMessage("user", question)]
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
```

## 4. 四个必踩的坑

### ① `import Swiftus` 会遮蔽 `_Concurrency.Task`

`SwiftusTasks` 定义了公开值类型 `Task`（任务中心的任务），伞产品 `@_exported import` 它之后，**消费方代码里的裸 `Task { }` 会解析到它并编不过**（报 `cannot convert value of type '_' to expected argument type 'JSONValue'` 这类看不懂的错）。

两种解法，任选：

```swift
// 写法 A：显式写全并发版本（用伞产品时必须这样）
_Concurrency.Task { … }

// 写法 B：只 import 具体模块，避开 SwiftusTasks
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import SwiftusCredentials
Task { … }            // 正常
```

### ② 所有 API 都是 `@ContextTreeActor` 隔离的

`Context` 及其成员的调用发生在模块自己的 global actor 上，视图模型（`@MainActor`）里不能直接碰：

```swift
@ContextTreeActor
final class IosRuntime {          // 盒子持有上下文树
    let context: Context
    init() throws { context = try Bootstrap.make() }
    func ask(_ q: String) async throws -> String { try await Bootstrap.ask(context, q) }
}

@MainActor
final class ChatViewModel: ObservableObject {
    private var runtime: IosRuntime?

    func start() {
        _Concurrency.Task { [weak self] in
            let made = try? await IosRuntime()   // 跨 actor 调构造
            self?.attach(made)                    // 闭包已继承 MainActor，无需再 hop
        }
    }

    func send(_ q: String) {
        guard let runtime else { return }
        _Concurrency.Task { [weak self] in
            let reply = try? await runtime.ask(q)
            self?.answer = reply ?? "（请求失败）"
        }
    }
}
```

要点：装配（`init`）与所有业务调用都要跨进 `ContextTreeActor`（`try? await`）；往 MainActor 的属性写回时，**若 `Task` 是在 `@MainActor` 方法里创建的，闭包已继承 MainActor，再写 `await` 反而会告警**。

### ③ 凭据：别硬编码 Key，Keychain 还没实现

包内**没有** Keychain 凭据来源（只有 env / memory / file / vault / aws）。生产做法二选一：

- **文件来源**（示例用的）：把 `{"ARK_API_KEY": "sk-…"}` 写进 Application Support；
- **自己实现 `Credentials` 协议**（推荐，走 Keychain）：协议只有 `get` / `update` / `addChangeListener` / `removeChangeListener` / `keys` / `refresh` / `close` 七项，Keychain 版本约 40 行，注入方式与 `FileCredentials` 相同。

`OpenAiCompatibleProvider` 在构造期解析 Key，之后由**凭据变更推送就地轮换**（不重建 HTTP 客户端），所以 Key 更新无需重建 provider。

### ④ iOS 上没有 shell，且文件系统受沙盒约束

- **shell 领域整个不存在于 iOS**（无子进程）：`ShellExecutor` 端口、`shell` 服务键、本地后端、S17 的 shell 追踪装饰器全部收在 `#if os(macOS)` 内，iOS 表面不暴露。将来要在 iOS 跑命令（WKWebView JS 沙箱 / 端侧执行服务）需按 S18 协议新增实现；
- **fs / database 走宿主磁盘，iOS 上受沙盒约束**：只能碰 Application Support / Documents，「任意路径读写」不成立。`JsonDatabaseBackend` 缺省目录已按平台分支（iOS 落 Application Support/database）。

## 5. 平台能力对照

| 能力 | iOS | macOS |
|---|---|---|
| Core（上下文树 / 可逆效应 / JSONValue / 脱敏） | ✅ | ✅ |
| Foundation 14 域中的 fs / database / logger / timer / loader / time-context / session / tools / prompt / memory | ✅（受沙盒约束） | ✅ |
| Skills（Yams 解析 frontmatter） | ✅（需引入 Yams） | ✅ |
| Credentials 五来源 + SigV4 | ✅（env 来源在 iOS 无意义） | ✅ |
| LLM / Compaction / Schedule / Agent / Tasks | ✅ | ✅ |
| **shell（执行命令）** | ❌ 整域不存在 | ✅ |
| Cron / Search / MCP | ❌ 尚无实现 | ❌ 尚无实现 |

## 6. 验证样例本身没腐化

样例不入 SwiftPM target（它在 `docs/` 下），改动后请手工跑一次 iOS 类型检查：

```bash
# 1) 先为 iOS 编译出各模块（产物在 /tmp/iosdd/Build/Products/Debug-iphoneos）
for s in SwiftusCore SwiftusFoundation SwiftusCredentials SwiftusLLM \
         SwiftusCompaction SwiftusSchedule SwiftusSkill SwiftusAgent SwiftusTasks Swiftus; do
  xcodebuild -scheme $s -destination 'generic/platform=iOS' -derivedDataPath /tmp/iosdd build
done

# 2) 确认 iOS 产物里 shell 符号数为 0（macOS 侧约 235）——只编译过不能证明「域不在」
nm /tmp/iosdd/Build/Intermediates.noindex/swiftus.build/Debug-iphoneos/\
SwiftusFoundation.build/Objects-normal/arm64/Shell.o | grep -c Shell   # 期望 0

# 3) 样例类型检查（伞产品 import 需要 CYaml 的 module map）
Y=$(find /tmp/iosdd/SourcePackages/checkouts/Yams/Sources/CYaml/include -name module.modulemap)
xcrun -sdk iphoneos swiftc -target arm64-apple-ios16.0 -typecheck -swift-version 6 \
  -I /tmp/iosdd/Build/Products/Debug-iphoneos \
  -Xcc -fmodule-map-file="$Y" -Xcc -I"$(dirname "$Y")" \
  docs/samples/IosIntegrationSample.swift
```

## 7. 已知缺口（v0.1.0）

- `SwiftusCron` / `SwiftusSearch` / `SwiftusMCP` 三个 target 为空声明，无实现（对应规格 S9 / S11 未开始）；
- **无 Keychain 凭据来源**，需自实现或用文件来源；
- 无 iOS 端 shell 后端；
- 无 CI；包的上游仓库也没有 CI 流水线。
