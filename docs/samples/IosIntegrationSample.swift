// iOS 接入示例：以 iOS SDK 类型检查验证过（xcrun -sdk iphoneos swiftc -typecheck）。
// 场景：App 内跑一条「提问 → 工具调用 → 回填 → 收口」的最小回路。
import Foundation
import Swiftus
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM

/// 端点与模型按需改；`credentialKey` 对应凭据源里的键名。
private func makeConfig() -> OpenAiConfig {
    var config = OpenAiConfig(
        name: "ark",
        baseUrl: "https://ark.cn-beijing.volces.com/api/v3",
        model: "doubao-seed-1-6"
    )
    config.credentialKey = "ARK_API_KEY"
    return config
}

@ContextTreeActor
enum IosIntegrationSample {
    /// 装配：凭据（沙盒文件）→ 工具 → prompt → 时间锚点 → LLM。
    static func bootstrap() throws -> Context {
        let app = Context.root(name: "ios-app")

        // 1) 凭据：Key 放沙盒文件里（别硬编码进二进制）。
        //    文件内容：{"ARK_API_KEY": "sk-xxx"}
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let credentials = FileCredentials(path: support.appending(path: "api-keys.json").path)
        // 装配是同步的，load 是异步的：真实 App 里在启动任务里 await load 即可。
        _ = try provideCredentials(app, credentials: credentials)

        // 2) 工具：ParamSpec 白名单投影 + 参数校验 + 失败码收敛。
        let tools = try provideTools(app)
        try tools.fn("now", description: "返回当前时刻") { _ in
            .success(ISO8601DateFormatter().string(from: Date()))
        }

        // 3) 时间锚点：日粒度「今天」注入 system prompt（跨天自动更新）。
        _ = try provideSystemPrompt(app)
        _ = try provideTimePrompt(app)

        // 4) LLM：OpenAI 兼容 wire 层，按凭据键取 Key，凭据变更自动就地轮换。
        _ = OpenAiCompatibleProvider(config: makeConfig(), credentials: credentials)

        // 整条链随 app 上下文释放：凭据 close、LLM 退订、工具清理。
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
        let system = prompt.renderContexts(prompt.assemble())

        var messages: [LlmMessage] = [
            LlmMessage("system", system),
            LlmMessage("user", question),
        ]
        for _ in 0..<8 {
            let result = try await llm.chat(LlmRequest(messages: messages, tools: tools.describe()))
            guard !result.toolCalls.isEmpty else { return result.content }
            messages.append(.toolCallRequest(result.toolCalls, content: result.content))
            for call in result.toolCalls {
                let arguments = (try? JSONValue.parse(Data(call.arguments.utf8)))?.objectValue ?? [:]
                let outcome = await tools.call(ToolCall(
                    name: call.name,
                    callId: call.id,
                    arguments: arguments
                ))
                messages.append(.toolResult(call.id, outcome.content))
            }
        }
        return "（达到轮次上限）"
    }
}

// ── SwiftUI 侧：从视图模型调用（iOS SDK 类型检查通过）──────────────────────
import SwiftUI

/// 上下文树由这个 `@ContextTreeActor` 盒子持有：视图模型不直接碰 `Context`，
/// 只在 Task 里跨 actor 调用（`Context` 的成员都是 ContextTreeActor 隔离的）。
@ContextTreeActor
final class IosRuntime {
    let context: Context

    init() throws {
        context = try IosIntegrationSample.bootstrap()
    }

    func ask(_ question: String) async throws -> String {
        try await IosIntegrationSample.ask(context, question)
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var answer = ""
    @Published private(set) var busy = false

    private var runtime: IosRuntime?

    func start() {
        // 装配也要跨进 ContextTreeActor；写回 MainActor 的属性要显式 hop。
        Task { [weak self] in
            let made = try? await IosRuntime()
            // attach 是 MainActor 隔离的，但本闭包已继承 MainActor（Task 在
            // @MainActor 方法内创建）→ 无需再 await。
            self?.attach(made)
        }
    }

    private func attach(_ runtime: IosRuntime?) {
        self.runtime = runtime
    }

    func send(_ question: String) {
        busy = true
        guard let runtime else { return }
        Task { [weak self] in
            // 裸 `Task { }` 直接可用（早期 SwiftusTasks 的任务值类型名 `Task`
            // 曾遮蔽并发 Task，已改名 `SwiftusTask`，规格 S17 §7）。
            let reply = try? await runtime.ask(question)
            // 闭包已继承 MainActor，写 @Published 属性无需再 hop。
            self?.finish(reply)
        }
    }

    private func finish(_ reply: String?) {
        answer = reply ?? "（请求失败）"
        busy = false
    }
}
