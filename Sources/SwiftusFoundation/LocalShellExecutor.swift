#if os(macOS)
import Foundation
import SwiftusCore

/// 基于本地子进程的默认执行器（规格 S18 §5）。
///
/// 用 `bash -c` 运行命令（非 Windows 分支，AGENTS 已定不移植），采集有上限的
/// stdout / stderr，支持前台超时与后台进程句柄。
///
/// **不可逆声明**：命令一旦执行，其对外部世界的效果（写文件、发请求、删数据……）
/// 无法被任何撤销函数回滚。这里只返回进程句柄；不存在、也不假装存在能还原副作用的逆
/// ——调用前的审批 / 守卫是唯一的防线。
@ContextTreeActor
public final class LocalShellExecutor: ShellExecutor {
    /// 面向模型的终端环境：关闭颜色、分页器与交互特性，避免输出被转义码污染。
    public static let envOverrides: [String: String] = [
        "NO_COLOR": "1",
        "TERM": "dumb",
        "PAGER": "cat",
        "GIT_PAGER": "cat",
    ]

    /// exitCode 落定后等待管道关闭的宽限期：进程被杀后其孙进程可能以孤儿身份持有
    /// 管道写端，使流迟迟不关闭；宽限期过后按已采集快照返回，不挂到孤儿退出。
    public static let pipeSettleGrace: TimeInterval = 0.25

    /// 相对工作目录的默认基准；缺省用进程当前目录。
    public let cwd: String?
    /// 默认前台超时（毫秒）。
    public let timeoutMs: Int
    /// 单次超时覆盖的上限（毫秒）。
    public let maxTimeoutMs: Int
    /// 单路输出的内存采集上限（字节）。
    public let maxOutputBytes: Int
    /// 等待缝（超时 / 宽限期）：生产 `Task.sleep`，测试注入受控等待器。
    public let waiter: any ShellWaiter

    public init(
        cwd: String? = nil,
        timeoutMs: Int = 120_000,
        maxTimeoutMs: Int = 600_000,
        maxOutputBytes: Int = 64_000,
        waiter: any ShellWaiter = TaskShellWaiter()
    ) {
        self.cwd = cwd
        self.timeoutMs = timeoutMs
        self.maxTimeoutMs = maxTimeoutMs
        self.maxOutputBytes = maxOutputBytes
        self.waiter = waiter
    }

    public func resolve(_ request: ShellExecRequest) -> ShellExecSpec {
        let requested = request.timeoutMs ?? timeoutMs
        return ShellExecSpec(
            command: request.command,
            workdir: request.workdir ?? cwd ?? FileManager.default.currentDirectoryPath,
            timeoutMs: min(requested, maxTimeoutMs),
            stdoutMaxBytes: request.stdoutMaxBytes ?? maxOutputBytes,
            stdin: request.stdin,
            env: request.env,
            cancelSignal: request.cancelSignal
        )
    }

    public func run(_ spec: ShellExecSpec) async throws -> ShellRunResult {
        let process = try Self.spawn(spec)
        Self.writeStdin(process.process, spec.stdin)
        if let cancel = spec.cancelSignal {
            _Concurrency.Task {
                await cancel()
                process.process.terminate()
            }
        }
        let stdout = BoundedOutputCollector(maxBytes: spec.stdoutMaxBytes)
        let stderr = BoundedOutputCollector(maxBytes: maxOutputBytes)
        stdout.start(process.stdout)
        stderr.start(process.stderr)

        // 超时先行中断：用等待器而不是阻塞计时器，便于测试受控推进。
        let timedOut = TimeoutFlag()
        let timeoutTask = _Concurrency.Task { [waiter] in
            try? await waiter.wait(Double(spec.timeoutMs) / 1000)
            guard !Task.isCancelled else { return }
            timedOut.trip()
            process.process.terminate()
        }
        let code = Self.exitCode(of: await Self.awaitExit(process.process))
        timeoutTask.cancel()
        _ = await Self.awaitSettled([stdout, stderr], waiter: waiter)
        return ShellRunResult(
            exitCode: code,
            timedOut: timedOut.value,
            timeoutMs: spec.timeoutMs,
            stdout: stdout.snapshot(),
            stderr: stderr.snapshot()
        )
    }

    public func start(_ spec: ShellExecSpec) async throws -> any ShellProcess {
        let process = try Self.spawn(spec)
        Self.writeStdin(process.process, spec.stdin)
        return LocalShellProcess(
            process: process.process,
            maxBytes: maxOutputBytes,
            stdout: process.stdout,
            stderr: process.stderr
        )
    }

    // MARK: - 起进程

    struct Spawned {
        let process: Process
        let stdout: Pipe
        let stderr: Pipe
    }

    static func spawn(_ spec: ShellExecSpec) throws -> Spawned {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", spec.command]
        process.currentDirectoryURL = URL(fileURLWithPath: spec.workdir)
        process.environment = Self.envOverrides.merging(spec.env ?? [:]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = Pipe()
        try process.run()
        return Spawned(process: process, stdout: stdout, stderr: stderr)
    }

    static func writeStdin(_ process: Process, _ input: String?) {
        guard let pipe = process.standardInput as? Pipe else { return }
        if let input, let data = input.data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
        try? pipe.fileHandleForWriting.close()
    }

    /// 等进程退出并取状态码（`waitUntilExit` 会阻塞调用线程，故走 terminationHandler）。
    static func awaitExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
        }
    }

    /// 退出码：正常退出取退出码，被信号杀死为负数（macOS/Linux 的 SIGKILL 为 -9）。
    static func exitCode(of status: Int32) -> Int {
        Int(status)
    }

    /// 等全部采集器落定，最长一个宽限期；逾期按已落定处理。
    static func awaitSettled(_ collectors: [BoundedOutputCollector], waiter: any ShellWaiter) async {
        for collector in collectors {
            await collector.finish(grace: Self.pipeSettleGrace, waiter: waiter)
        }
    }
}

/// 超时标记：跨任务共享的一次性布尔（锁盒，不占 actor）。
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tripped
    }

    func trip() {
        lock.lock()
        tripped = true
        lock.unlock()
    }
}

/// 等待缝（规格 S18 §7 的 Clock 纪律）：超时与管道宽限期都走它。
public protocol ShellWaiter: Sendable {
    /// 等待若干秒；抛错表示等待被取消。
    func wait(_ seconds: TimeInterval) async throws
}

/// 生产实现：`Task.sleep`。
public struct TaskShellWaiter: ShellWaiter {
    public init() {}

    public func wait(_ seconds: TimeInterval) async throws {
        try await _Concurrency.Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// 有界采集：把管道持续收进缓冲；`snapshot()` 随时可取（规格 S18 §5.2）。
///
/// 与「等采集 future」的区别：缓冲随时可快照——进程被杀后若孙进程孤儿持有管道
/// 写端，流迟迟不关闭，调用方可以宽限期后取走已采集部分。
final class BoundedOutputCollector: @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var truncatedFlag = false
    private var finishedFlag = false
    private var waiters: [@Sendable () -> Void] = []

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    /// 启动采集；读到空 chunk 即 EOF（Foundation 在 EOF 时以空 Data 回调）。
    func start(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.markFinished()
                return
            }
            self.append(chunk)
        }
    }

    /// 等流关闭（EOF），最长一个宽限期。
    ///
    /// 进程被杀后其孙进程可能以孤儿身份持有管道写端，EOF 迟迟不来；宽限期到则
    /// 按已落定处理，调用方取走已采集快照，而不是挂到孤儿退出（规格 S18 §5.2）。
    func finish(grace: TimeInterval, waiter: any ShellWaiter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let settled: Bool = lock.withLock { () -> Bool in
                if finishedFlag { return true }
                waiters.append({ continuation.resume() })
                return false
            }
            if settled {
                continuation.resume()
                return
            }
            _Concurrency.Task { [weak self] in
                try? await waiter.wait(grace)
                self?.markFinished()
            }
        }
    }

    /// 当前已采集内容的快照（不结束采集）。
    func snapshot() -> CollectedOutput {
        lock.lock()
        defer { lock.unlock() }
        return CollectedOutput(
            text: String(decoding: buffer, as: UTF8.self),
            truncated: truncatedFlag
        )
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count >= maxBytes {
            truncatedFlag = true
            return
        }
        let remaining = maxBytes - buffer.count
        if chunk.count <= remaining {
            buffer.append(chunk)
        } else {
            buffer.append(chunk.prefix(remaining))
            truncatedFlag = true
        }
    }

    func markFinished() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            finishedFlag = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter() }
    }
}

/// 后台进程句柄：缓冲输出，增量读取与终止（规格 S18 §5.3）。
@ContextTreeActor
public final class LocalShellProcess: ShellProcess {
    private let process: Process
    private let maxBytes: Int
    private let stdoutBuffer = OutputBuffer()
    private let stderrBuffer = OutputBuffer()
    private var state: ShellProcessStatus = .running
    private var code: Int?
    private var settled: Task<Void, Never>

    public var status: ShellProcessStatus {
        state
    }

    public var exitCode: Int? {
        code
    }

    public var done: Task<Void, Never> {
        settled
    }

    init(process: Process, maxBytes: Int, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.maxBytes = maxBytes
        stdoutBuffer.resize(maxBytes)
        stderrBuffer.resize(maxBytes)
        stdoutBuffer.start(stdout)
        stderrBuffer.start(stderr)
        // 先占位再赋真实任务：初始化未完成时闭包不能捕获 self。
        settled = _Concurrency.Task {}
        settled = _Concurrency.Task { [weak self] in
            let status = await LocalShellExecutor.awaitExit(process)
            guard let self else { return }
            code = LocalShellExecutor.exitCode(of: status)
            if state == .running {
                state = .completed
            }
            stdoutBuffer.finish()
            stderrBuffer.finish()
        }
    }

    public func readOutput() -> ShellProcessRead {
        let out = stdoutBuffer.drain()
        let err = stderrBuffer.drain()
        return ShellProcessRead(
            delta: Self.joinOutput(out.text, err.text),
            lossy: out.lossy || err.lossy
        )
    }

    @discardableResult
    public func kill() -> Bool {
        guard state == .running else { return false }
        state = .killed
        process.terminate()
        return true
    }

    static func joinOutput(_ out: String, _ err: String) -> String {
        if err.isEmpty { return out }
        let section = "[stderr]\n" + err
        return out.isEmpty ? section : out + "\n" + section
    }
}

/// 后台进程的输出缓冲：消费式增量读取（读走即清空游标之前的部分）。
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var offset = 0
    private var lossyFlag = false
    private var maxBytes = 0
    private var finishedFlag = false

    func resize(_ bytes: Int) {
        lock.lock()
        maxBytes = bytes
        lock.unlock()
    }

    func start(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            lock.lock()
            if buffer.count - offset >= maxBytes {
                lossyFlag = true
            } else {
                let remaining = maxBytes - (buffer.count - offset)
                buffer.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
                if chunk.count > remaining { lossyFlag = true }
            }
            lock.unlock()
        }
    }

    /// 读走自上次以来的增量。
    func drain() -> (text: String, lossy: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let slice = offset < buffer.count ? buffer[offset...] : Data()
        offset = buffer.count
        let lossy = lossyFlag
        lossyFlag = false
        return (String(decoding: slice, as: UTF8.self), lossy)
    }

    func finish() {
        lock.lock()
        finishedFlag = true
        lock.unlock()
    }
}

#endif
