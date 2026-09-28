import Foundation
import SwiftusCore

/// 一路被采集的输出（可能因超过上限被截断）。
public struct CollectedOutput: Sendable, Equatable {
    public let text: String
    public let truncated: Bool?
    public let spillPath: String?

    public init(text: String, truncated: Bool? = nil, spillPath: String? = nil) {
        self.text = text
        self.truncated = truncated
        self.spillPath = spillPath
    }
}

/// 前台命令的**请求**：可缺省字段由 `ShellExecutor.resolve` 依据实现配置补齐（规格 S18 §4）。
public struct ShellExecRequest: Sendable {
    public let command: String
    public var workdir: String?
    /// 超时覆盖（毫秒）；实现会封顶。
    public var timeoutMs: Int?
    public var stdoutMaxBytes: Int?
    /// 写入 stdin 后立即关闭；缺省表示不写。
    public var stdin: String?
    /// 追加环境变量。
    public var env: [String: String]?
    /// 取消信号：落定时终止进程。
    public var cancelSignal: (@Sendable () async -> Void)?

    public init(
        command: String,
        workdir: String? = nil,
        timeoutMs: Int? = nil,
        stdoutMaxBytes: Int? = nil,
        stdin: String? = nil,
        env: [String: String]? = nil,
        cancelSignal: (@Sendable () async -> Void)? = nil
    ) {
        self.command = command
        self.workdir = workdir
        self.timeoutMs = timeoutMs
        self.stdoutMaxBytes = stdoutMaxBytes
        self.stdin = stdin
        self.env = env
        self.cancelSignal = cancelSignal
    }
}

extension ShellExecRequest: Equatable {
    /// 取消信号不参与相等（闭包不可比）。
    public static func == (lhs: ShellExecRequest, rhs: ShellExecRequest) -> Bool {
        lhs.command == rhs.command
            && lhs.workdir == rhs.workdir
            && lhs.timeoutMs == rhs.timeoutMs
            && lhs.stdoutMaxBytes == rhs.stdoutMaxBytes
            && lhs.stdin == rhs.stdin
            && lhs.env == rhs.env
    }
}

/// 解析后的**执行规格**：必填字段已由 `ShellExecutor.resolve` 补齐并封顶。
public struct ShellExecSpec: Sendable {
    public let command: String
    /// 已解析的工作目录。
    public let workdir: String
    /// 已封顶的超时（毫秒）。
    public let timeoutMs: Int
    /// 已解析的 stdout 采集上限（字节）。
    public let stdoutMaxBytes: Int
    public let stdin: String?
    public let env: [String: String]?
    public let cancelSignal: (@Sendable () async -> Void)?

    public init(
        command: String,
        workdir: String,
        timeoutMs: Int,
        stdoutMaxBytes: Int,
        stdin: String? = nil,
        env: [String: String]? = nil,
        cancelSignal: (@Sendable () async -> Void)? = nil
    ) {
        self.command = command
        self.workdir = workdir
        self.timeoutMs = timeoutMs
        self.stdoutMaxBytes = stdoutMaxBytes
        self.stdin = stdin
        self.env = env
        self.cancelSignal = cancelSignal
    }
}

extension ShellExecSpec: Equatable {
    /// 取消信号不参与相等（闭包不可比）。
    public static func == (lhs: ShellExecSpec, rhs: ShellExecSpec) -> Bool {
        lhs.command == rhs.command
            && lhs.workdir == rhs.workdir
            && lhs.timeoutMs == rhs.timeoutMs
            && lhs.stdoutMaxBytes == rhs.stdoutMaxBytes
            && lhs.stdin == rhs.stdin
            && lhs.env == rhs.env
    }
}

/// 一次前台运行的结局（规格 S18 §4）。
///
/// 正交的结局各自独立上报：进程可能既超时又以 0 退出，故 `timedOut` 与 `exitCode`
/// 互不覆盖；被信号杀死时 `exitCode` 是**负数**（macOS/Linux 的 SIGKILL 为 `-9`）。
public struct ShellRunResult: Sendable, Equatable {
    public let exitCode: Int?
    public let timedOut: Bool
    /// 本次实际生效的超时（毫秒）。
    public let timeoutMs: Int
    public let stdout: CollectedOutput
    public let stderr: CollectedOutput

    public init(
        exitCode: Int?,
        timedOut: Bool,
        timeoutMs: Int,
        stdout: CollectedOutput,
        stderr: CollectedOutput
    ) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.timeoutMs = timeoutMs
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 后台进程的生命周期状态。
public enum ShellProcessStatus: String, Sendable, Equatable {
    case running, completed, killed
}

/// 一次增量的 `readOutput()` 读取：自上次调用以来产生的内容。
public struct ShellProcessRead: Sendable, Equatable {
    /// 增量输出（stderr 以标记段拼接）。
    public let delta: String
    /// 是否因截断丢失了增量无法包含的字节。
    public let lossy: Bool
    public let stdoutSpillPath: String?
    public let stderrSpillPath: String?

    public init(
        delta: String,
        lossy: Bool = false,
        stdoutSpillPath: String? = nil,
        stderrSpillPath: String? = nil
    ) {
        self.delta = delta
        self.lossy = lossy
        self.stdoutSpillPath = stdoutSpillPath
        self.stderrSpillPath = stderrSpillPath
    }
}

/// 后台进程句柄：唯一的访问入口，退出后缓冲输出仍可读（规格 S18 §4）。
@ContextTreeActor
public protocol ShellProcess: AnyObject, Sendable {
    /// 生命周期状态（恰好落定一次）。
    var status: ShellProcessStatus { get }
    /// 结束后的退出码（仍在运行为 nil；被信号杀死为负数）。
    var exitCode: Int? { get }
    /// 进程落定时完成；永不 reject。
    var done: Task<Void, Never> { get }
    /// 读取自上次调用以来产生的新输出（消费式，不重复投递）。
    func readOutput() -> ShellProcessRead
    /// 终止进程；进程已结束时返回 false（幂等）。
    @discardableResult
    func kill() -> Bool
}

/// 命令执行能力缝（规格 S18 §4，服务键 `shell`）。
///
/// 实现必须遵守：
/// - `run` 只对基础设施故障 reject；非零退出、超时中断、取消中断都以 `ShellRunResult` 正常返回；
/// - `start` 立即返回句柄；后台进程无超时，`done` 在进程结束时落定且永不 reject；
/// - `readOutput` 是增量的：连续读取不重复输出。
@ContextTreeActor
public protocol ShellExecutor: AnyObject, Sendable {
    /// 依据实现配置补齐并封顶请求，产出可交给 `run` / `start` 的规格。
    func resolve(_ request: ShellExecRequest) -> ShellExecSpec
    /// 前台执行，进程结束时返回。
    func run(_ spec: ShellExecSpec) async throws -> ShellRunResult
    /// 启动后台进程并立即返回句柄。
    func start(_ spec: ShellExecSpec) async throws -> any ShellProcess
}

/// 'shell' 服务键。
extension ServiceKey where Service == any ShellExecutor {
    public static let shell = ServiceKey<any ShellExecutor>("shell")
}

/// 将执行器作为 `shell` 服务提供到上下文（规格 S18 §6）。
@ContextTreeActor
@discardableResult
public func provideShell(_ ctx: Context, executor: any ShellExecutor) throws -> any ShellExecutor {
    try ctx.provide(.shell, executor)
    return executor
}

/// 提供本地执行器为 `shell` 服务（规格 S18 §6）。
@ContextTreeActor
@discardableResult
public func provideShellLocal(_ ctx: Context, executor: (any ShellExecutor)? = nil) throws -> any ShellExecutor {
    try provideShell(ctx, executor: executor ?? LocalShellExecutor())
}
