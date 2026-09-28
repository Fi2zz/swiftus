import Foundation
import SwiftusCore
import SwiftusFoundation

/// 把一次会话（含派生事件）记录进 SessionLog 的记录器（规格 S4 §6.3）。
///
/// 业务 Session 仍是**模型可见的唯一真相源**；SessionLog 是它的**超集**：
/// 镜像全部业务事件，再追加派生事件。日志为每条事件分配自己的 seq；派生事件的
/// parentEventId 指向已记录的最后一条事件，整个会话在日志里是一条因果链。
/// 写入串行化，保证链与追加顺序在多路调用下依然稳定。
@ContextTreeActor
public final class SessionLogRecorder {
    /// 目标日志。
    public let log: any SessionLog

    /// 是否在每次 llm/request 落盘后、发送前校验「模型可见即已记录」
    ///（开发模式开启；生产保持关闭——每次校验都要回读一遍会话日志）。
    public let strictModelVisible: Bool

    /// 正在镜像的会话 id；未 attach 时为 nil。
    public private(set) var sessionId: String?

    /// 已记录的最后一条事件 id（派生事件的 parentEventId）。
    public private(set) var lastEventId: String?

    private var detachDisposer: Disposer?
    private var detachToken: UUID?
    private var chainTail: Task<Void, Never>?

    public init(log: any SessionLog, strictModelVisible: Bool = false) {
        self.log = log
        self.strictModelVisible = strictModelVisible
    }

    /// 开始镜像 session：先补记已有事件，再订阅后续追加。
    /// 返回幂等撤销；重复调用会先撤销上一次订阅。
    @discardableResult
    public func attach(_ session: Session) -> Disposer {
        detach()
        sessionId = session.id
        session.replay { [weak self] event in
            self?.mirrorLater(event)
        }
        let off = session.onEvent { [weak self] event in
            self?.mirrorLater(event)
        }
        let token = UUID()
        detachDisposer = off
        detachToken = token
        return { [weak self] in
            try off()
            guard let self, self.detachToken == token else { return }
            self.detachDisposer = nil
            self.detachToken = nil
        }
    }

    /// 停止镜像当前会话。
    public func detach() {
        if let disposer = detachDisposer {
            try? disposer()
        }
        detachDisposer = nil
        detachToken = nil
    }

    /// 记一条派生事件（非模型可见）；尚未 attach 时静默忽略。
    /// 写入串行化；错误透传给调用方，且不卡住后续写入。
    public func record(_ type: String, data: JSONValue? = nil) async throws {
        guard let sessionId else { return }
        try await enqueueAppend { lastEventId in
            SessionEvent(
                seq: 0,
                type: type,
                time: Date(),
                data: data,
                id: SessionEventIds.next(),
                sessionId: sessionId,
                parentEventId: lastEventId
            )
        }?.value
    }

    /// 镜像一条业务事件：自带 parentEventId 时保留（业务因果），否则接到链尾。
    /// 事件监听是同步回调——**同步入链**（不包外层 Task），保证镜像与派生写入的
    /// 相对顺序同追加顺序（Dart `_serialize` 语义）；结果丢弃，错误吞掉。
    private func mirrorLater(_ event: SessionEvent) {
        enqueueAppend { lastEventId in
            var mirrored = event
            if mirrored.parentEventId == nil {
                mirrored.parentEventId = lastEventId
            }
            return mirrored
        }
    }

    /// 串行化写入：入链同步完成（链尾立即推进）；任务体在执行时刻才取
    /// lastEventId 并前推（链序保证读到最新值，与 Dart `_serialize` 一致）。
    /// 链尾吞错不卡后续；调用方可经返回的 Task 拿到原始错误。
    @discardableResult
    private func enqueueAppend(
        _ makeEvent: @escaping @ContextTreeActor (String?) -> SessionEvent
    ) -> Task<Void, any Error>? {
        let previous = chainTail
        let current = Task<Void, any Error> { [weak self, log] in
            await previous?.value
            guard let self else { return }
            let recorded = try await log.append(makeEvent(self.lastEventId))
            self.lastEventId = recorded.id
        }
        chainTail = Task {
            _ = try? await current.value
        }
        return current
    }
}

/// 记录每一次工具调用（`tool/call`）；group 用于 MCP 等来源归因（规格 S4 §6.1）。
/// 工具**结果**不重复记录：业务会话的 `tool/result` 事件已被镜像。
@ContextTreeActor
@discardableResult
public func instrumentSessionLogTools(_ tools: ToolRegistry, recorder: SessionLogRecorder) -> Disposer {
    let token = tools.use { call, next in
        try await recorder.record(kToolCallEvent, data: .object([
            "name": .string(call.name),
            "callId": .string(call.callId),
            "group": tools.groupOf(call.name).map { .string($0) } ?? .null,
            "args": .object(call.arguments),
        ]))
        return try await next()
    }
    return {
        tools.removePipelineListener(token)
    }
}

/// 'sessionLogRecorder' 服务键。
extension ServiceKey where Service == SessionLogRecorder {
    public static let sessionLogRecorder = ServiceKey<SessionLogRecorder>("sessionLogRecorder")
}

/// 将 SessionLogRecorder 作为 'sessionLogRecorder' 服务提供到上下文（规格 S4 §6.3）。
/// 依赖 'sessionLog' 服务，缺少时自动补一个（provideSessionLog）。
@ContextTreeActor
@discardableResult
public func provideSessionLogRecorder(
    _ ctx: Context,
    recorder: SessionLogRecorder? = nil,
    strictModelVisible: Bool = false
) throws -> SessionLogRecorder {
    if let recorder {
        try ctx.provide(.sessionLogRecorder, recorder)
        return recorder
    }
    let log = try ctx.get(.sessionLog) ?? provideSessionLog(ctx)
    let resolved = SessionLogRecorder(log: log, strictModelVisible: strictModelVisible)
    try ctx.provide(.sessionLogRecorder, resolved)
    return resolved
}
