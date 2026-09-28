import SwiftusLLM

/// 上下文体量的粗粒度估算（规格 S16 §6.3）：「约 4 个字符 1 个 token」，只用于
/// 相对度量（压缩前后对比、缓存前缀大小、趋势观察），不用于计费或硬预算判断。

/// 粗略估算文本的 token 数：字符数除以 4 向上取整，空串为 0。
public func estimateTokens(_ text: String) -> Int {
    text.isEmpty ? 0 : (text.count + 3) / 4
}

/// 粗略估算一组消息的 token 数：逐条累加 role、content 与工具调用
///（工具调用计入 id、名字与参数串——它们在请求体里同样是真实负载）。
public func estimateMessagesTokens(_ messages: [LlmMessage]) -> Int {
    var total = 0
    for message in messages {
        total += estimateTokens(message.role) + estimateTokens(message.content)
        for call in message.toolCalls {
            total += estimateTokens(call.id) + estimateTokens(call.name) + estimateTokens(call.arguments)
        }
    }
    return total
}
