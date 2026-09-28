import Foundation
import SwiftusCore

/// 文件系统错误码（规格 S18 §1）。
public enum FsErrorCode: String, Sendable, Equatable {
    case notFound = "FS_NOT_FOUND"
    case notDirectory = "FS_NOT_DIRECTORY"
    case notText = "FS_NOT_TEXT"
    case notRegularFile = "FS_NOT_REGULAR_FILE"
    case tooLarge = "FS_TOO_LARGE"
    case permissionDenied = "FS_PERMISSION_DENIED"
    case sandboxDenied = "FS_SANDBOX_DENIED"
    case ioError = "FS_IO_ERROR"
    case staleVersion = "FS_STALE_VERSION"
    case notObserved = "FS_NOT_OBSERVED"
    case ambiguousEdit = "FS_AMBIGUOUS_EDIT"
    case editNotFound = "FS_EDIT_NOT_FOUND"
    case aborted = "FS_ABORTED"
}

/// 带稳定错误码的文件系统异常（规格 S18 §1）。
public struct FsError: Error, Equatable {
    /// 机器可路由的错误码。
    public let code: FsErrorCode
    /// 人可读的消息。
    public let message: String

    public init(_ code: FsErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

extension FsError: CustomStringConvertible {
    public var description: String {
        "FsError(\(code.rawValue)): \(message)"
    }
}

/// 路径条目类型（规格 S18 §1）。
public enum FsFileType: String, Sendable, Equatable {
    case file, directory, symlink, other
}

/// 由后端解析出的稳定目标身份（规格 S18 §1）。
public struct FsTarget: Sendable, Equatable {
    /// 不透明键：用于陈旧守卫与目标查找，消费方不得解析。
    public let targetKey: String
    /// 面向模型 / 界面的路径。
    public let displayPath: String

    public init(targetKey: String, displayPath: String) {
        self.targetKey = targetKey
        self.displayPath = displayPath
    }
}

extension FsTarget: CustomStringConvertible {
    public var description: String {
        "FsTarget(\(displayPath))"
    }
}

/// `stat` 返回的元数据（规格 S18 §1）；目标不存在时为 nil。
public struct FsInfo: Sendable, Equatable {
    /// 不透明的新鲜度令牌。
    public let version: String
    /// 目标类型。
    public let type: FsFileType
    /// 普通文件的字节大小。
    public let size: Int?

    public init(version: String, type: FsFileType, size: Int? = nil) {
        self.version = version
        self.type = type
        self.size = size
    }
}

/// 不跟随链接的路径元数据（规格 S18 §1）。
public struct FsPathInfo: Sendable, Equatable {
    public let version: String
    public let type: FsFileType
    public let size: Int?

    public init(version: String, type: FsFileType, size: Int? = nil) {
        self.version = version
        self.type = type
        self.size = size
    }
}

/// `listDir` 返回的一个直接子项：只含元数据与已解析目标（规格 S18 §1）。
public struct FsDirEntry: Sendable, Equatable {
    public let name: String
    public let type: FsFileType
    public let target: FsTarget
    public let size: Int?

    public init(name: String, type: FsFileType, target: FsTarget, size: Int? = nil) {
        self.name = name
        self.type = type
        self.target = target
        self.size = size
    }
}

/// 带守卫的写入意图（规格 S18 §1）：省略即无条件创建 / 覆盖。
public enum FsWriteIntent: Sendable, Equatable {
    /// 仅在目标不存在时创建；已存在则 `notObserved`。
    case createIfAbsent
    /// 仅在目标仍处于给定版本时替换。
    case replaceIfVersion(String)
}

/// 写入操作类型（规格 S18 §1）。
public enum FsWriteOperation: String, Sendable, Equatable {
    case create, update
}

/// 整文件写入的结局（规格 S18 §1）。
public struct FsWriteOutcome: Sendable, Equatable {
    public let operation: FsWriteOperation
    /// 写入后的版本令牌。
    public let version: String
    /// 写入前的完整内容；新建或后端放弃提供时为 nil。
    public let before: String?
    /// 写入后的完整内容。
    public let after: String

    public init(operation: FsWriteOperation, version: String, before: String?, after: String) {
        self.operation = operation
        self.version = version
        self.before = before
        self.after = after
    }
}

/// 字面替换的编辑请求（规格 S18 §1）。
public struct FsEditRequest: Sendable, Equatable {
    /// 要替换的字面文本；非空且必须精确匹配。
    public let oldString: String
    /// 替换文本；空串表示删除匹配内容。
    public let newString: String
    /// 替换全部匹配，而非要求恰好一处。
    public let replaceAll: Bool

    public init(oldString: String, newString: String, replaceAll: Bool = false) {
        self.oldString = oldString
        self.newString = newString
        self.replaceAll = replaceAll
    }
}

/// 字面编辑的结局（规格 S18 §1）。
public struct FsEditOutcome: Sendable, Equatable {
    public let version: String
    public let before: String
    public let after: String

    public init(version: String, before: String, after: String) {
        self.version = version
        self.before = before
        self.after = after
    }
}
