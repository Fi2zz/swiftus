import Foundation
import os
import SwiftusCore
import SwiftusFoundation

/// 一条审批请求（规格 S16 §6.2）。
public struct ApprovalRequest: Sendable, Equatable {
    /// 请求 id。
    public let id: String
    /// 待审批的工具名（`plan` 表示整份计划）。
    public let toolName: String
    /// 工具参数。
    public let arguments: [String: JSONValue]
    /// 面向用户的说明。
    public let description: String
    /// 本请求涉及的文件系统路径（Tool.pathParams 声明的参数取值）。
    public let pathArgs: [String]
    /// 请求时间。
    public let createdAt: Date

    public init(
        id: String,
        toolName: String,
        arguments: [String: JSONValue] = [:],
        description: String = "",
        pathArgs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.description = description
        self.pathArgs = pathArgs
        self.createdAt = createdAt
    }
}

/// 审批端口（规格 S16 §6.2，服务键 'approval'）。
@ContextTreeActor
public protocol Approval: Sendable {
    /// 是否批准该请求。
    func request(_ request: ApprovalRequest) async -> Bool

    /// 待处理请求流（供 UI/外部系统订阅）。
    var pending: AsyncStream<ApprovalRequest> { get }

    /// 是否已预先放行该请求，无需打扰用户；缺省 false（每次都问）。
    /// 中间件在 request 之前调用它：返回 true 则直接放行，不产生审批请求、
    /// 不发遥测、不弹界面。
    func preapproved(_ request: ApprovalRequest) async -> Bool

    /// 一次性审批整份计划（缺省走同一条 request，toolName 为 plan）。
    func requestPlan(_ plan: Plan) async -> Bool

    /// 释放资源（缺省无操作）。幂等。
    func close()
}

extension Approval {
    public func preapproved(_ request: ApprovalRequest) async -> Bool {
        false
    }

    public func requestPlan(_ plan: Plan) async -> Bool {
        await request(ApprovalRequest(
            id: "plan-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
            toolName: "plan",
            arguments: plan.jsonValue.objectValue ?? [:],
            description: plan.summary()
        ))
    }

    public func close() {}
}

/// 自动批准或拒绝（测试/默认 provider）。
@ContextTreeActor
public final class AutoApproval: Approval {
    /// 是否批准。
    public let approved: Bool
    /// 收到过的请求数。
    public private(set) var requests = 0

    private let broadcaster = PendingBroadcaster()

    public init(_ approved: Bool) {
        self.approved = approved
    }

    public var pending: AsyncStream<ApprovalRequest> {
        broadcaster.stream
    }

    public func request(_ request: ApprovalRequest) async -> Bool {
        requests += 1
        broadcaster.publish(request)
        return approved
    }

    public func close() {
        broadcaster.finish()
    }
}

/// 按规则批准：返回 true 即放行。
@ContextTreeActor
public final class RuleBasedApproval: Approval {
    /// 判定规则。
    public let allow: @Sendable (ApprovalRequest) -> Bool

    private let broadcaster = PendingBroadcaster()

    public init(allow: @escaping @Sendable (ApprovalRequest) -> Bool) {
        self.allow = allow
    }

    public var pending: AsyncStream<ApprovalRequest> {
        broadcaster.stream
    }

    public func request(_ request: ApprovalRequest) async -> Bool {
        broadcaster.publish(request)
        return allow(request)
    }

    public func close() {
        broadcaster.finish()
    }
}

/// 经 ask_user 询问用户；超时或异常视为拒绝（规格 S16 §6.2）。
@ContextTreeActor
public final class AskUserApproval: Approval {
    /// 提问器。
    public let askUser: any AskUser
    /// 视为「是」的回答（小写比较）。
    public let yesWords: Set<String>
    /// 审批超时（秒），超时视为拒绝。
    public let timeout: TimeInterval

    private let broadcaster = PendingBroadcaster()

    public init(
        askUser: any AskUser,
        yesWords: Set<String> = ["y", "yes", "是", "允许", "可以", "好"],
        timeout: TimeInterval = 300
    ) {
        self.askUser = askUser
        self.yesWords = yesWords
        self.timeout = timeout
    }

    public var pending: AsyncStream<ApprovalRequest> {
        broadcaster.stream
    }

    public func request(_ request: ApprovalRequest) async -> Bool {
        broadcaster.publish(request)
        let prompt = "是否允许执行 \"\(request.toolName)\"？"
            + (request.description.isEmpty ? "" : "（\(request.description)）")
            + " (y/N)"
        do {
            let answer = try await raceTimeout(seconds: timeout) {
                try await self.askUser.ask(prompt)
            }
            return yesWords.contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
        } catch {
            return false
        }
    }

    public func close() {
        broadcaster.finish()
    }
}

/// 审批超时（视为拒绝）。
public struct ApprovalTimeoutError: Error {}

/// 竞速停止等待：work 与超时赛跑，先到者胜，迟到结果被完成守卫丢弃
///（与坑 #任务组一致：不用 withTaskGroup 等待全部子任务）。
@ContextTreeActor
public func raceTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @ContextTreeActor () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        var finished = false
        let complete: @ContextTreeActor (Result<T, any Error>) -> Void = { outcome in
            guard !finished else { return }
            finished = true
            continuation.resume(with: outcome)
        }
        Task {
            do {
                complete(.success(try await operation()))
            } catch {
                complete(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            complete(.failure(ApprovalTimeoutError()))
        }
    }
}

/// 待处理请求广播器：订阅者各得一条流（锁盒，跨域安全）。
@ContextTreeActor
final class PendingBroadcaster {
    private struct State {
        var subscribers: [UUID: AsyncStream<ApprovalRequest>.Continuation] = [:]
        var closed = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var stream: AsyncStream<ApprovalRequest> {
        AsyncStream { continuation in
            let token = UUID()
            state.withLock { current -> Void in
                if current.closed {
                    continuation.finish()
                } else {
                    current.subscribers[token] = continuation
                }
            }
            continuation.onTermination = { [state] _ in
                state.withLock { current -> Void in
                    current.subscribers.removeValue(forKey: token)
                }
            }
        }
    }

    func publish(_ request: ApprovalRequest) {
        state.withLock { current -> Void in
            guard !current.closed else { return }
            for subscriber in current.subscribers.values {
                subscriber.yield(request)
            }
        }
    }

    func finish() {
        state.withLock { current -> Void in
            guard !current.closed else { return }
            current.closed = true
            for subscriber in current.subscribers.values {
                subscriber.finish()
            }
            current.subscribers.removeAll()
        }
    }
}
