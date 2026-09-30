#if os(macOS)
import Foundation
import SwiftusCore

/// 以子进程管道为通道的传输（规格 S11 §5）。
///
/// stdout 逐行解析 JSON-RPC；解析不了的那一行只写诊断，不会杀死连接。
/// stderr 也全量进诊断。子进程退出或管道中断时，消息流收到一个
/// `server-exited` 错误并随即关闭——上层的等待因此不会永久挂起。
///
/// **整条 stdio 域是 macOS 专属**（规格 S11 §9 的有意偏离）：来源用 `dart:io`
/// 的 `Process` 起子进程，Foundation 的 `Process` 在 iOS 上不可用。iOS 表面
/// 不暴露本类型；装配一个 `stdio` server 时由 `defaultMcpTransport` 明确失败
/// 并说明原因，而不是编译期就缺符号。
@ContextTreeActor
public final class StdioTransport: McpTransport {
    private let command: String
    private let args: [String]
    private let env: [String: String]
    private let workingDirectory: String?

    /// 消息接收端。
    public let sink = McpMessageSink()
    /// 诊断总线。
    public let diagnostics = McpDiagnostics()

    private var process: Process?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    public init(
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.args = args
        self.env = env
        self.workingDirectory = workingDirectory
    }

    /// 连接是否已建立且尚未断开。
    public var connected: Bool { sink.connected }

    public func messages() -> AsyncStream<McpTransportEvent> {
        sink.stream()
    }

    @discardableResult
    public func observeDiagnostics(_ body: @escaping @Sendable (String) -> Void) -> Int {
        diagnostics.observe(body)
    }

    public func connect() async throws {
        guard sink.connected == false, process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        // 环境变量是**宿主环境 + 配置注入**的合并。
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in env { merged[key] = value }
        process.environment = merged
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = Pipe()

        do {
            try process.run()
        } catch {
            throw McpException(
                McpException.Codes.notConnected,
                "MCP server \"\(command)\" 启动失败：\(error)"
            )
        }
        self.process = process
        sink.connected = true
        diagnostics.log("已启动 MCP 子进程 \(command)")

        stdoutTask = readLines(outPipe.fileHandleForReading) { [weak self] line in
            self?.handleStdout(line)
        }
        stderrTask = readLines(errPipe.fileHandleForReading) { [weak self] line in
            // stderr 全量进诊断。
            self?.diagnostics.log(line)
        }
        // 子进程退出 → 消息流收到 server-exited 并关闭。
        //
        // 用 `terminationHandler` 而不是「另起线程 `waitUntilExit`」：后者要占住一个
        // 线程阻塞等进程，而 `DispatchQueue.global` 的 worker 在全量并发下会被本仓
        // 其他阻塞读（管道 `availableData`）挤占，utility 队列迟迟排不上——表现为
        // 「子进程早退了，测试却等不到 server-exited」的偶发红（本仓在 CI 前夜踩到，
        // debug 复现一次、release 复现一次）。`terminationHandler` 由 Foundation
        // 在内部队列上回调，不占本进程的线程。
        process.terminationHandler = { [weak self] finished in
            Task { @ContextTreeActor in
                guard let self else { return }
                self.sink.connected = false
                self.sink.emitFailure(McpException(
                    McpException.Codes.serverExited,
                    "MCP server \"\(self.command)\" 已退出（状态 \(finished.terminationStatus)）"
                ))
                self.sink.finish()
            }
        }
    }

    public func disconnect() async {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        stdoutTask = nil
        stderrTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        sink.connected = false
        sink.finish()
        diagnostics.dispose()
    }

    public func send(_ message: McpMessage) async throws {
        guard let process, sink.connected, let stdin = process.standardInput as? Pipe else {
            throw McpException(McpException.Codes.notConnected, "stdio 传输未连接")
        }
        // 逐行 JSON-RPC：一行一条消息，末尾补换行。
        var line = try JSONValue.object(message.json).jsonData()
        line.append(0x0A)
        stdin.fileHandleForWriting.write(line)
    }

    /// stdout 逐行解析；解析不了的那一行只写诊断，不杀连接。
    private func handleStdout(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let decoded = McpDecode.text(trimmed), case let .object(json) = decoded else {
            diagnostics.log("无法解析的 MCP 载荷：\(trimmed)")
            return
        }
        sink.emit(McpMessage(json: json))
    }

    /// 逐行读取一个文件句柄（不假设按行到达：按 `\n` 切分，跨块重组）。
    ///
    /// `availableData` 是**阻塞**调用，必须放到专用线程上跑：留在协作线程池里
    /// 会占满线程，让同一进程里的 `Task.sleep` / URLSession 回调一起饿死
    /// （本项目在 S11 测试里实测到过一次挂死）。
    private func readLines(
        _ handle: FileHandle,
        onLine: @escaping @ContextTreeActor (String) -> Void
    ) -> Task<Void, Never> {
        let queue = DispatchQueue(label: "swiftus.mcp.stdio.read", qos: .utility)
        let sink = self.sink
        return Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    var buffer = Data()
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let index = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<index]
                            buffer.removeSubrange(buffer.startIndex...index)
                            let line = String(decoding: lineData, as: UTF8.self)
                            Task { @ContextTreeActor in onLine(line) }
                        }
                    }
                    if !buffer.isEmpty {
                        let line = String(decoding: buffer, as: UTF8.self)
                        Task { @ContextTreeActor in onLine(line) }
                    }
                    // 管道到 EOF：故障由 waitUntilExit 那边统一收口，避免两处都发。
                    _ = sink
                    continuation.resume()
                }
            }
        }
    }
}
#endif
