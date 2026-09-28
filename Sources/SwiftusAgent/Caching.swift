import Foundation
import SwiftusCore
import SwiftusLLM

/// 一次请求的可缓存前缀度量（规格 S16 §6.2）。
///
/// 服务端按**请求前缀**自动缓存：只要每轮请求的前缀逐字节相同，重复部分就命中。
public struct CachePlan: Sendable, Equatable {
    /// 前缀的稳定指纹（内容相同必得同值；具体值是实现细节，fixtures 不比对）。
    public let cacheKey: String
    /// 前缀包含的消息条数。
    public let cacheableMessages: Int
    /// 前缀包含的正文字符数（不含 role 与工具调用）。
    public let cacheableChars: Int
    /// 前缀是否为空（没有任何可缓存消息）。
    public let empty: Bool

    /// 求 messages 从头的**连续**可缓存前缀：遇到第一条 cacheable == false 即停止，
    /// 后续即使又出现可缓存消息也不计入。
    ///
    /// 前缀判定依据消息自身内容（chatItem），因此尾部增删消息不影响指纹，
    /// 前缀内任何一条消息变化都会改变指纹。
    public static func of(_ messages: [LlmMessage]) -> CachePlan {
        var prefix: [JSONValue] = []
        var chars = 0
        for message in messages {
            guard message.cacheable else { break }
            prefix.append(message.chatItem)
            chars += message.content.count
        }
        return CachePlan(
            cacheKey: fingerprint(prefix),
            cacheableMessages: prefix.count,
            cacheableChars: chars,
            empty: prefix.isEmpty
        )
    }

    /// FNV-1a 64 位指纹（Dart 同款：初值 0xcbf29ce484222325，质数 0x100000001b3）。
    private static func fingerprint(_ prefix: [JSONValue]) -> String {
        guard let data = try? JSONValue.array(prefix).jsonData() else { return "0" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

/// 前缀缓存的能力对象（规格 S16 §6.2，服务键 'contextCache'）：算计划、记命中、发遥测。
@ContextTreeActor
public final class ContextCache {
    private let telemetry: (any Telemetry)?
    private var hitCount = 0
    private var missCount = 0

    /// telemetry 为 nil 时不发事件（也不报错）。
    public init(telemetry: (any Telemetry)? = nil) {
        self.telemetry = telemetry
    }

    /// 累计命中次数。
    public var hits: Int {
        hitCount
    }

    /// 累计未命中次数。
    public var misses: Int {
        missCount
    }

    /// 求 messages 的可缓存前缀（纯函数，无副作用）。
    public func planFor(_ messages: [LlmMessage]) -> CachePlan {
        CachePlan.of(messages)
    }

    /// 记录一次调用的缓存结果并产出 context.cache 遥测。
    ///
    /// usage 是提供方返回的原始用量表；命中与否由它派生，一个命中字段都取不到
    /// 时按未命中计（保守口径）。
    public func recordHit(plan: CachePlan, usage: [String: JSONValue]) {
        let cached = cachedHit(usage)
        if cached {
            hitCount += 1
        } else {
            missCount += 1
        }
        telemetry?.emit(TelemetryEvent("context.cache", data: [
            "cacheKey": .string(plan.cacheKey),
            "cacheableMessages": .int(Int64(plan.cacheableMessages)),
            "cacheableChars": .int(Int64(plan.cacheableChars)),
            "hit": .bool(cached),
        ]))
    }

    /// 命中判定：prompt_cache_hit_tokens / cache_hit_tokens /
    /// prompt_tokens_details.cached_tokens 任一为正值。
    private func cachedHit(_ usage: [String: JSONValue]) -> Bool {
        if positive(usage["prompt_cache_hit_tokens"]) { return true }
        if positive(usage["cache_hit_tokens"]) { return true }
        guard case let .object(details) = usage["prompt_tokens_details"] else { return false }
        return positive(details["cached_tokens"])
    }

    private func positive(_ value: JSONValue?) -> Bool {
        if case let .int(number) = value { return number > 0 }
        if case let .double(number) = value { return number > 0 }
        return false
    }
}

/// 缓存度量装饰器（规格 S16 §6.2）：请求与流式调用原样透传，只补一次命中度量——
/// **不往请求体加任何字段**（非标字段可能被 400 拒绝）。
@ContextTreeActor
public final class CachingLlmProvider: LlmProvider {
    /// 被包装的提供方。
    public let inner: any LlmProvider
    /// 缓存能力对象。
    public let cache: ContextCache

    public init(_ inner: any LlmProvider, cache: ContextCache) {
        self.inner = inner
        self.cache = cache
    }

    public var name: String {
        inner.name
    }

    public func chat(_ request: LlmRequest) async throws -> LlmResult {
        let plan = cache.planFor(request.messages)
        let result = try await inner.chat(request)
        cache.recordHit(plan: plan, usage: result.usage)
        return result
    }

    public func chatStream(_ request: LlmRequest) -> AsyncThrowingStream<LlmStreamEvent, any Error> {
        inner.chatStream(request)
    }

    public func close() {
        inner.close()
    }
}

/// 'contextCache' 服务键。
extension ServiceKey where Service == ContextCache {
    public static let contextCache = ServiceKey<ContextCache>("contextCache")
}

/// 把 ContextCache 作为 'contextCache' 服务提供到上下文；
/// telemetry 缺省取上下文里已提供的 'telemetry'。
@ContextTreeActor
@discardableResult
public func provideContextCache(
    _ ctx: Context,
    cache: ContextCache? = nil,
    telemetry: (any Telemetry)? = nil
) throws -> ContextCache {
    let resolved = cache ?? ContextCache(telemetry: telemetry ?? ctx.get(.telemetry))
    try ctx.provide(.contextCache, resolved)
    return resolved
}
