import Foundation
import SwiftusCore
import SwiftusLLM

/// 脚本化模型（对齐 Dart agent_loop_test 的 _ScriptedProvider）：
/// 按调用次数顺序返回预设结果；脚本耗尽后重复最后一条。
@ContextTreeActor
final class ScriptedProvider: LlmProvider {
    let script: [LlmResult]
    private(set) var calls: [[LlmMessage]] = []
    private(set) var lastTools: [JSONValue]?

    /// chat 挂起标记（取消竞速测试用）。
    var hang = false

    init(_ script: [LlmResult]) {
        self.script = script
    }

    var name: String {
        "scripted"
    }

    func chat(_ request: LlmRequest) async throws -> LlmResult {
        if hang {
            try await Task.sleep(for: .seconds(30))
        }
        calls.append(request.messages)
        lastTools = request.tools
        let index = min(calls.count - 1, script.count - 1)
        return script[index]
    }

    func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// 纯文本响应。
func scriptedText(_ content: String) -> LlmResult {
    LlmResult(content: content, provider: "scripted", model: "m")
}

/// 工具调用响应。
func scriptedCall(_ id: String, _ name: String, args: String = "{}") -> LlmResult {
    var result = scriptedText("")
    result.toolCalls = [LlmToolCall(id: id, name: name, arguments: args)]
    return result
}
