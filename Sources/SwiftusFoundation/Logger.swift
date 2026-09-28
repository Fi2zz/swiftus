import Foundation
import SwiftusCore

/// 日志级别，严重度 `debug < info < warn < error`（规格 S19 §4）。
public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    /// 严重度，越大越严重。
    public var severity: Int {
        rawValue
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 一条结构化日志（规格 S19 §4）。
public struct LogRecord: Sendable {
    public let level: LogLevel
    public let name: String
    public let message: String
    public let time: Date
    public let error: String?
    public let stackTrace: String?

    public init(
        level: LogLevel,
        name: String,
        message: String,
        time: Date,
        error: String? = nil,
        stackTrace: String? = nil
    ) {
        self.level = level
        self.name = name
        self.message = message
        self.time = time
        self.error = error
        self.stackTrace = stackTrace
    }
}

/// 日志导出器（sink；规格 S19 §4）。
@ContextTreeActor
public protocol LogExporter: AnyObject {
    /// 导出一条日志。
    func export(_ record: LogRecord)
}

/// 写一整行的 sink。
public typealias LogWriter = @Sendable (String) -> Void

/// 内置日志服务（规格 S19 §4，服务键 `logger`）。
@ContextTreeActor
public final class LoggerService {
    /// 直接用服务方法记录日志时使用的名字。
    public let defaultName: String
    /// 全局最小级别；低于它的日志被丢弃。
    public var level: LogLevel
    /// `recent` 保留的最大条数。
    public var recentLimit: Int
    /// 时刻源（测试注入固定时刻，生产读系统时间）。
    private let now: @Sendable () -> Date

    private var exporterList: [any LogExporter] = []
    private var recentRecords: [LogRecord] = []

    public init(
        defaultName: String = "root",
        level: LogLevel = .info,
        recentLimit: Int = 100,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaultName = defaultName
        self.level = level
        self.recentLimit = recentLimit
        self.now = now
    }

    /// 已登记的导出器（只读副本）。
    public var exporters: [any LogExporter] {
        exporterList
    }

    /// 最近记录的日志（至多 `recentLimit` 条，只读副本）。
    public var recent: [LogRecord] {
        recentRecords
    }

    /// 创建一个命名 logger。
    public func logger(_ name: String? = nil) -> Logger {
        Logger(name: name ?? defaultName, service: self)
    }

    /// 登记一个导出器。
    public func addExporter(_ exporter: any LogExporter) {
        exporterList.append(exporter)
    }

    /// 移除一个导出器；返回是否确实移除了**同一实例**。
    @discardableResult
    public func removeExporter(_ exporter: any LogExporter) -> Bool {
        guard let index = exporterList.firstIndex(where: { $0 === exporter }) else { return false }
        exporterList.remove(at: index)
        return true
    }

    public func debug(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        emit(.debug, defaultName, message, error, stackTrace)
    }

    public func info(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        emit(.info, defaultName, message, error, stackTrace)
    }

    public func warn(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        emit(.warn, defaultName, message, error, stackTrace)
    }

    public func error(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        emit(.error, defaultName, message, error, stackTrace)
    }

    /// 记录顺序：过级别 → 建记录 → 进环形缓冲 → 依次交给导出器（规格 S19 §4）。
    func emit(_ messageLevel: LogLevel, _ name: String, _ message: String, _ error: String?, _ stackTrace: String?) {
        guard messageLevel.severity >= level.severity else { return }
        let record = LogRecord(
            level: messageLevel,
            name: name,
            message: message,
            time: now(),
            error: error,
            stackTrace: stackTrace
        )
        recentRecords.append(record)
        if recentRecords.count > recentLimit {
            recentRecords.removeFirst(recentRecords.count - recentLimit)
        }
        // 快照遍历：导出器里注销自己不影响本次派发。
        for exporter in exporterList {
            exporter.export(record)
        }
    }
}

/// 命名 logger 门面（规格 S19 §4）。
@ContextTreeActor
public final class Logger {
    public let name: String
    private let service: LoggerService

    init(name: String, service: LoggerService) {
        self.name = name
        self.service = service
    }

    public func debug(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        service.emit(.debug, name, message, error, stackTrace)
    }

    public func info(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        service.emit(.info, name, message, error, stackTrace)
    }

    public func warn(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        service.emit(.warn, name, message, error, stackTrace)
    }

    public func error(_ message: String, _ error: String? = nil, _ stackTrace: String? = nil) {
        service.emit(.error, name, message, error, stackTrace)
    }
}

/// 控制台导出器：格式 `[I] name  message`（规格 S19 §4）。
@ContextTreeActor
public final class ConsoleExporter: LogExporter {
    private let writer: LogWriter
    /// 导出器自身的级别过滤；nil 表示不过滤（由服务级别决定）。
    public let level: LogLevel?
    /// 是否在行首输出 ISO 时间。
    public let showTime: Bool

    public init(writer: @escaping LogWriter = { print($0) }, level: LogLevel? = nil, showTime: Bool = false) {
        self.writer = writer
        self.level = level
        self.showTime = showTime
    }

    public func export(_ record: LogRecord) {
        if let threshold = level, record.level.severity < threshold.severity {
            return
        }
        var line = ""
        if showTime {
            line += record.time.formatted(Date.ISO8601FormatStyle()) + " "
        }
        line += "[\(Self.tag(record.level))] \(record.name)  \(record.message)"
        if let error = record.error {
            line += " \(error)"
        }
        writer(line)
        if let stackTrace = record.stackTrace {
            writer(stackTrace)
        }
    }

    static func tag(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "D"
        case .info: return "I"
        case .warn: return "W"
        case .error: return "E"
        }
    }
}

extension ServiceKey where Service == LoggerService {
    public static let logger = ServiceKey<LoggerService>("logger")
}

/// 将 `LoggerService` 提供到上下文，并按需挂上控制台导出器（规格 S19 §4）。
@ContextTreeActor
@discardableResult
public func provideLogger(
    _ ctx: Context,
    logger: LoggerService? = nil,
    level: LogLevel = .info,
    console: Bool = true,
    writer: LogWriter? = nil,
    showTime: Bool = false
) throws -> LoggerService {
    let service = logger ?? LoggerService(defaultName: ctx.name, level: level)
    try ctx.provide(.logger, service)
    if console {
        let exporter = ConsoleExporter(
            writer: writer ?? { print($0) },
            showTime: showTime
        )
        service.addExporter(exporter)
        // 释放路径只摘掉**本插件**挂的那个导出器。
        ctx.onDispose { service.removeExporter(exporter) }
    }
    return service
}
