import SwiftusCore

/// OpenAI 兼容端点的请求形态（规格 S10 §1）。
public enum LlmApiStyle: String, Sendable {
    case chat
    case responses
}

/// 模型请求的一次工具调用。
public struct LlmToolCall: Sendable, Equatable {
    /// 调用标识（与工具结果消息的 toolCallId 配对）。
    public let id: String

    /// 工具名。
    public let name: String

    /// 原始 JSON 参数串（未解析）。
    public let arguments: String

    public init(id: String, name: String, arguments: String = "{}") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// 编译为 Chat Completions 的 tool_call 项。
    public var chatItem: JSONValue {
        .object([
            "id": .string(id),
            "type": .string("function"),
            "function": .object(["name": .string(name), "arguments": .string(arguments)]),
        ])
    }
}

/// 聊天消息携带的图片（多模态输入）。
public struct LlmImage: Sendable, Equatable {
    public let mimeType: String
    public let base64Data: String

    public init(mimeType: String, base64Data: String) {
        self.mimeType = mimeType
        self.base64Data = base64Data
    }

    /// data URL 形式，chat 的 image_url 与 responses 的 input_image 共用。
    public var dataUrl: String {
        "data:\(mimeType);base64,\(base64Data)"
    }
}

/// 聊天消息（规格 S10 §2）。
///
/// 普通消息 `LlmMessage("user", "你好")`；工具调用与工具结果用
/// `toolCallRequest` / `toolResult` 工厂构造。
public struct LlmMessage: Sendable, Equatable {
    public var role: String // system / user / assistant / tool
    public var content: String

    /// 助手消息请求的工具调用。
    public var toolCalls: [LlmToolCall] = []

    /// 工具结果消息对应的调用 id（role 为 tool 时必填）。
    public var toolCallId: String?

    /// 可缓存稳定前缀的纯本地标记，**不会**写入请求体。
    public var cacheable = false

    /// 消息携带的图片；为空时退化为纯文本。
    public var images: [LlmImage] = []

    public init(_ role: String, _ content: String) {
        self.role = role
        self.content = content
    }

    /// 助手工具调用消息。
    public static func toolCallRequest(_ calls: [LlmToolCall], content: String = "") -> LlmMessage {
        var message = LlmMessage("assistant", content)
        message.toolCalls = calls
        return message
    }

    /// 工具结果消息。
    public static func toolResult(_ callId: String, _ content: String) -> LlmMessage {
        var message = LlmMessage("tool", content)
        message.toolCallId = callId
        return message
    }

    /// 编译为 Chat Completions 的 message 项。
    public var chatItem: JSONValue {
        var fields: [String: JSONValue] = ["role": .string(role)]
        fields["content"] = images.isEmpty ? .string(content) : multimodalContent()
        if let toolCallId { fields["tool_call_id"] = .string(toolCallId) }
        if !toolCalls.isEmpty { fields["tool_calls"] = .array(toolCalls.map(\.chatItem)) }
        return .object(fields)
    }

    private func multimodalContent() -> JSONValue {
        .array([.object(["type": .string("text"), "text": .string(content)])] + images.map {
            .object([
                "type": .string("image_url"),
                "image_url": .object(["url": .string($0.dataUrl)]),
            ])
        })
    }
}

/// 聊天补全结果。
public struct LlmResult: Sendable, Equatable {
    public var content: String
    public var provider: String
    public var model: String
    public var usage: [String: JSONValue] = [:]

    /// 模型请求的工具调用；无工具调用时为空。
    public var toolCalls: [LlmToolCall] = []

    /// 模型的思考过程（如 reasoning_content）；未输出时为空串。
    public var reasoning = ""

    public init(content: String, provider: String, model: String) {
        self.content = content
        self.provider = provider
        self.model = model
    }
}

/// 流结束终态：携带累计用量、结束原因与工具调用（规格 S10 §5）。
/// 由 chatStream 在流末尾产出一次；流中途失败则不产出。
public struct LlmStreamDone: Sendable, Equatable {
    public var usage: [String: JSONValue] = [:]
    public var finishReason: String?

    /// 流式累积完成的工具调用；工具参数以 JSON 分片到达，终态一次性给出。
    public var toolCalls: [LlmToolCall] = []

    /// 产出该流的提供商名（供 streamChatResult 还原 LlmResult）。
    public var provider = ""

    /// 产出该流的模型名；未知时为空串。
    public var model = ""

    public init() {}
}

/// 流式事件三类（规格 S10 §5）。
public enum LlmStreamEvent: Sendable, Equatable {
    /// 正文增量。
    case textDelta(String)
    /// 思考增量。
    case reasoningDelta(String)
    /// 流结束终态。
    case done(LlmStreamDone)
}

/// 提供商调用失败时抛出（规格 S10 §10）。
public struct LlmException: Error, Equatable, Sendable {
    public let provider: String
    public let message: String
    public let statusCode: Int?

    public init(_ provider: String, _ message: String, statusCode: Int? = nil) {
        self.provider = provider
        self.message = message
        self.statusCode = statusCode
    }
}

extension LlmException: CustomStringConvertible {
    public var description: String {
        "LlmException(\(provider), \(statusCode.map(String.init) ?? "nil")): \(message)"
    }
}

/// 一次聊天补全的请求参数。
public struct LlmRequest: Sendable {
    public var messages: [LlmMessage]

    /// 并入并覆盖请求体顶层字段的选项（如 temperature）。
    public var options: [String: JSONValue]?

    /// 工具 schema 列表（`{name, description, parameters}` 白名单三键）。
    public var tools: [JSONValue]?

    public init(messages: [LlmMessage], options: [String: JSONValue]? = nil, tools: [JSONValue]? = nil) {
        self.messages = messages
        self.options = options
        self.tools = tools
    }
}
