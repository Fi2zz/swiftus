import Foundation
import SwiftusCore

/// 宿主文件系统后端（规格 S18 §3）：读写宿主磁盘。
///
/// 目标身份由 realpath 派生（别名共享同一键），写入经临时文件 + rename 原子
/// 发布，编辑在守卫校验后做字面替换。相对路径以构造时的 `cwd` 为基准。
///
/// IO 不经 actor 串行：文件操作量大，串到 `ContextTreeActor` 上会拖垮整棵上下文树；
/// 本类只在边界上触碰协议（`@ContextTreeActor` 的方法体很短），内部 IO 直接走
/// Foundation。
@ContextTreeActor
public final class LocalFileSystem: FileSystem {
    /// 相对路径的解析基准。
    public let cwd: String

    public init(cwd: String? = nil) {
        self.cwd = cwd ?? FileManager.default.currentDirectoryPath
    }

    public func resolve(_ path: String, cwd: String?) async throws -> FsTarget {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FsError(.notFound, "file_path must be a non-empty string")
        }
        let displayPath = Self.normalize(Self.absolute(path, cwd ?? self.cwd))
        let key = Self.identity(of: displayPath)
        return FsTarget(targetKey: key, displayPath: displayPath)
    }

    public func processPath(_ target: FsTarget) -> String {
        target.targetKey
    }

    public func fileUrl(_ target: FsTarget) -> String {
        URL(fileURLWithPath: processPath(target)).absoluteString
    }

    public func contains(_ parent: FsTarget, _ child: FsTarget) -> Bool {
        Self.pathContains(processPath(parent), processPath(child))
    }

    public func stat(_ target: FsTarget) async throws -> FsInfo? {
        try Self.statInfo(at: target.targetKey)
    }

    public func lstat(_ path: String, cwd: String?) async throws -> FsPathInfo? {
        let resolved = Self.normalize(Self.absolute(path, cwd ?? self.cwd))
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved)
        guard let attributes else { return nil }
        // 最后一段是符号链接时：**类型**取链接自身（不跟随，Foundation 的
        // attributesOfItem 也不跟随），**大小**按 Dart 实际行为跟随链接取目标大小
        // （S18 §7 偏离：Dart 的 lstat 类型不跟随、大小跟随）。
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let linkTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: resolved))
                ?? resolved
            let followed = try? FileManager.default.attributesOfItem(atPath: linkTarget)
            let size = followed.map(Self.fileType) == .file
                ? (followed?[.size] as? NSNumber)?.intValue
                : nil
            return FsPathInfo(
                version: Self.version(resolved: resolved, attributes: attributes),
                type: .symlink,
                size: size
            )
        }
        let type = Self.fileType(attributes)
        let size = type == .file ? (attributes[.size] as? NSNumber)?.intValue : nil
        return FsPathInfo(
            version: Self.version(resolved: resolved, attributes: attributes),
            type: type,
            size: size
        )
    }

    public func readText(_ target: FsTarget) async throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.targetKey)
        guard let attributes else {
            throw FsError(.notFound, "cannot read \"\(target.displayPath)\": not found")
        }
        guard Self.fileType(attributes) == .file else {
            throw FsError(.notRegularFile, "cannot read \"\(target.displayPath)\": not a regular file")
        }
        guard let data = FileManager.default.contents(atPath: target.targetKey) else {
            throw FsError(.notFound, "cannot read \"\(target.displayPath)\": not found")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FsError(.notText, "cannot read \"\(target.displayPath)\": invalid UTF-8 text")
        }
        return text
    }

    public func listDir(_ target: FsTarget) async throws -> [FsDirEntry] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.targetKey)
        guard let attributes else {
            throw FsError(.notFound, "cannot list \"\(target.displayPath)\": not found")
        }
        guard Self.fileType(attributes) == .directory else {
            throw FsError(.notDirectory, "cannot list \"\(target.displayPath)\": not a directory")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: target.targetKey)
        var entries: [FsDirEntry] = []
        for name in names.sorted() {
            let path = target.targetKey + "/" + name
            let childAttributes = try? FileManager.default.attributesOfItem(atPath: path)
            let type = childAttributes.map(Self.fileType) ?? .other
            let size = type == .file ? (childAttributes?[.size] as? NSNumber)?.intValue : nil
            entries.append(FsDirEntry(
                name: name,
                type: type,
                target: FsTarget(targetKey: path, displayPath: target.displayPath + "/" + name),
                size: size
            ))
        }
        return entries
    }

    public func writeText(
        _ target: FsTarget,
        _ content: String,
        expected: FsWriteIntent? = nil
    ) async throws -> FsWriteOutcome {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.targetKey)
        let exists = attributes != nil
        if let attributes, Self.fileType(attributes) != .file {
            throw FsError(.notRegularFile, "cannot write \"\(target.displayPath)\": not a regular file")
        }
        let version = attributes.map { Self.version(resolved: target.targetKey, attributes: $0) }
        try Self.checkWriteGuard(target: target, expected: expected, version: version)
        let before: String?
        if exists {
            before = try? await readText(target)
        } else {
            before = nil
        }
        try Self.writeAtomic(path: target.targetKey, content: content)
        let after = try Self.statInfo(at: target.targetKey)
        return FsWriteOutcome(
            operation: exists ? .update : .create,
            version: after?.version ?? "",
            before: before,
            after: content
        )
    }

    public func editText(
        _ target: FsTarget,
        _ edit: FsEditRequest,
        expectedVersion: String? = nil
    ) async throws -> FsEditOutcome {
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.targetKey)
        guard let attributes else {
            throw FsError(.staleVersion, "cannot edit \"\(target.displayPath)\": file changed since it was read")
        }
        guard Self.fileType(attributes) == .file else {
            throw FsError(.notRegularFile, "cannot edit \"\(target.displayPath)\": not a regular file")
        }
        let version = Self.version(resolved: target.targetKey, attributes: attributes)
        if let expectedVersion, version != expectedVersion {
            throw FsError(.staleVersion, "cannot edit \"\(target.displayPath)\": file changed since it was read")
        }
        let original = try await readText(target)
        let count = edit.oldString.isEmpty ? 0 : Self.occurrences(of: edit.oldString, in: original)
        if count == 0 {
            throw FsError(.editNotFound, "old_string was not found in \"\(target.displayPath)\"")
        }
        if !edit.replaceAll, count > 1 {
            throw FsError(.ambiguousEdit, "old_string matched \(count) times in \"\(target.displayPath)\"")
        }
        let edited = original.replacingOccurrences(of: edit.oldString, with: edit.newString)
        try Self.writeAtomic(path: target.targetKey, content: edited)
        let after = try Self.statInfo(at: target.targetKey)
        return FsEditOutcome(version: after?.version ?? "", before: original, after: edited)
    }

    public func remove(_ target: FsTarget) async throws {
        let path = target.targetKey
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            try FileManager.default.removeItem(atPath: path)
        } else {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - 路径与身份（规格 S18 §3.1 / §3.2）

    /// 路径规范化：按 `/` 与 `\` 切段（两平台都吃），跳过空段与 `.`，
    /// `..` 在有可回退段时回退；绝对路径保留前导分隔符。
    static func normalize(_ path: String) -> String {
        let absolute = isAbsolute(path)
        var parts: [String] = []
        for part in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            if part.isEmpty || part == "." { continue }
            if part == "..", let last = parts.last, last != ".." {
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    static func isAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") || windowsDrive.range(of: path, options: .regularExpression) != nil
    }

    private static let windowsDrive = #"^[A-Za-z]:[\\/]"#

    static func absolute(_ path: String, _ cwd: String) -> String {
        isAbsolute(path) ? path : normalize(cwd + "/" + path)
    }

    /// 目标身份：存在取真实路径；不存在取「父目录真实路径 + basename」；
    /// 父目录也不存在则退回展示路径（规格 S18 §3.2）。
    static func identity(of displayPath: String) -> String {
        let manager = FileManager.default
        if let resolved = try? manager.destinationOfSymbolicLink(atPath: displayPath),
           manager.fileExists(atPath: resolved) {
            return normalize(resolved)
        }
        if manager.fileExists(atPath: displayPath) {
            let parent = dirName(displayPath)
            let base = baseName(displayPath)
            if let realParent = try? manager.destinationOfSymbolicLink(atPath: parent),
               manager.fileExists(atPath: realParent) {
                return normalize(realParent + "/" + base)
            }
            return normalize(displayPath)
        }
        let parent = dirName(displayPath)
        let base = baseName(displayPath)
        if let realParent = try? manager.destinationOfSymbolicLink(atPath: parent),
           manager.fileExists(atPath: realParent) {
            return normalize(realParent + "/" + base)
        }
        return displayPath
    }

    static func dirName(_ path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "." }
        if index == path.startIndex { return "/" }
        return String(path[path.startIndex..<index])
    }

    static func baseName(_ path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: index)...])
    }

    static func pathContains(_ parent: String, _ child: String) -> Bool {
        let base = normalize(parent)
        let candidate = normalize(child)
        if candidate == base { return true }
        return candidate.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    // MARK: - 元数据与写入

    static func fileType(_ attributes: [FileAttributeKey: Any]) -> FsFileType {
        switch attributes[.type] as? FileAttributeType {
        case .some(.typeRegular): return .file
        case .some(.typeDirectory): return .directory
        case .some(.typeSymbolicLink): return .symlink
        default: return .other
        }
    }

    /// 新鲜度令牌：修改时刻 + 变更时刻 + 大小（格式由实现自定，跨实现不可比）。
    static func version(resolved: String, attributes: [FileAttributeKey: Any]) -> String {
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let changed = ((attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        return "\(Int(modified * 1_000_000)):\(Int(changed * 1_000_000)):\(size):\(resolved.hashValue)"
    }

    static func statInfo(at path: String) throws -> FsInfo? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let type = fileType(attributes)
        let size = type == .file ? (attributes[.size] as? NSNumber)?.intValue : nil
        return FsInfo(version: version(resolved: path, attributes: attributes), type: type, size: size)
    }

    static func checkWriteGuard(target: FsTarget, expected: FsWriteIntent?, version: String?) throws {
        switch expected {
        case let .replaceIfVersion(wanted):
            guard let version, version == wanted else {
                throw FsError(.staleVersion, "cannot write \"\(target.displayPath)\": file changed since it was read")
            }
        case .createIfAbsent:
            guard version == nil else {
                throw FsError(
                    .notObserved,
                    "cannot overwrite existing \"\(target.displayPath)\" without reading it first"
                )
            }
        case nil:
            break
        }
    }

    /// 原子发布：父目录递归创建 → 临时文件 → 替换目标。
    ///
    /// 三级降级（**`moveItem` 在目标已存在时会失败**，只写一次的文件看起来正常、
    /// 第二次以后全丢——本项目在 cron 存储上踩过一次）：
    /// 1. 目标已存在 → `replaceItemAt`（原子替换）；
    /// 2. 目标不存在 → `moveItem`（rename）；
    /// 3. 都不行 → 直接覆盖 + 清理临时文件（最后手段，非原子）。
    public static func writeAtomic(path: String, content: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: dirName(path), withIntermediateDirectories: true)
        let temp = "\(path).tmp-\(Int(Date().timeIntervalSince1970 * 1_000_000))"
        let data = Data(content.utf8)
        try data.write(to: URL(fileURLWithPath: temp))
        let destination = URL(fileURLWithPath: path)
        if manager.fileExists(atPath: path), (try? manager.replaceItemAt(destination, withItemAt: URL(fileURLWithPath: temp))) != nil {
            return
        }
        do {
            try manager.moveItem(atPath: temp, toPath: path)
        } catch {
            try data.write(to: destination)
            try? manager.removeItem(atPath: temp)
        }
    }

    /// 统计字面出现次数（非重叠计数，与 Dart 的 split 口径一致）。
    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
            if index == found.lowerBound { index = haystack.index(after: index) }
        }
        return count
    }
}
