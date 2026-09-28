import Foundation
import SwiftusCore

/// 抽象文件系统提供方（规格 S18 §2，服务键 `fs`）。
///
/// 目标必须在别名下保持身份一致；读取暴露普通 UTF-8 文本或类型化错误；
/// 目录列举稳定且不读内容；写入与编辑必须原子。
@ContextTreeActor
public protocol FileSystem: AnyObject {
    /// 把路径解析为稳定目标（相同文件必须产出相同 `targetKey`；相对路径以 `cwd` 为基准）。
    func resolve(_ path: String, cwd: String?) async throws -> FsTarget

    /// 本执行世界中子进程可打开的规范绝对路径。
    func processPath(_ target: FsTarget) -> String

    /// 规范 `file:` URI。
    func fileUrl(_ target: FsTarget) -> String

    /// `child` 是否就是 `parent` 或其子孙（按规范身份，不解析不透明键）。
    func contains(_ parent: FsTarget, _ child: FsTarget) -> Bool

    /// 目标元数据；不存在返回 nil。绝不返回内容。
    func stat(_ target: FsTarget) async throws -> FsInfo?

    /// 路径元数据，且不跟随最后一段符号链接。
    func lstat(_ path: String, cwd: String?) async throws -> FsPathInfo?

    /// 读取整个普通文本文件为解码后的字符串。
    func readText(_ target: FsTarget) async throws -> String

    /// 按名字稳定排序返回目录的直接子项；只含元数据。
    func listDir(_ target: FsTarget) async throws -> [FsDirEntry]

    /// 原子地创建或替换 UTF-8 文本；`expected` 提供意图与陈旧守卫。
    func writeText(_ target: FsTarget, _ content: String, expected: FsWriteIntent?) async throws -> FsWriteOutcome

    /// 原子地做字面替换编辑；`expectedVersion` 非空时先校验版本再匹配。
    func editText(_ target: FsTarget, _ edit: FsEditRequest, expectedVersion: String?) async throws -> FsEditOutcome

    /// 删除目标文件（或目录，递归）；目标不存在时静默返回。
    func remove(_ target: FsTarget) async throws
}

/// 'fs' 服务键。
extension ServiceKey where Service == any FileSystem {
    public static let fs = ServiceKey<any FileSystem>("fs")
}

/// 将文件系统作为 `fs` 服务提供到上下文（规格 S18 §6）。
@ContextTreeActor
@discardableResult
public func provideFileSystem(_ ctx: Context, fs: any FileSystem) throws -> any FileSystem {
    try ctx.provide(.fs, fs)
    return fs
}

/// 提供本地文件系统为 `fs` 服务（规格 S18 §6）。
@ContextTreeActor
@discardableResult
public func provideFileSystemLocal(_ ctx: Context, fs: (any FileSystem)? = nil) throws -> any FileSystem {
    try provideFileSystem(ctx, fs: fs ?? LocalFileSystem())
}
