import Foundation
import SwiftusCore

/// 家目录解析错误（规格 S4 §5）。
public enum HomeError: Error, Equatable {
    /// 解析不到用户目录（无 HOME / USERPROFILE）。
    case homeUnavailable
}

/// 环境变量 `SWIFTUS_HOME`：覆盖 swiftus 的用户级数据根目录（规格 S4 §5 实现注记）。
public let kSwiftusHomeEnv = "SWIFTUS_HOME"

/// swiftus 用户级数据根目录名（位于用户目录下）。
public let kSwiftusHomeDirName = ".swiftus"

/// 解析用户目录：`HOME` → `USERPROFILE`；都没有抛 HomeError.homeUnavailable。
/// env 可注入（测试用），缺省读进程环境。
public func resolveHomeDir(env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    if let home = nonBlank(env["HOME"]) ?? nonBlank(env["USERPROFILE"]) {
        return home
    }
    throw HomeError.homeUnavailable
}

/// 解析 swiftus 用户级数据根目录：`SWIFTUS_HOME` 非空优先，否则 `<用户目录>/.swiftus`。
/// 绝不在当前工作目录兜底（规格 S4 §5）。
public func resolveSwiftusHome(env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    if let overridden = nonBlank(env[kSwiftusHomeEnv]) {
        return overridden
    }
    return try resolveHomeDir(env: env) + "/" + kSwiftusHomeDirName
}

/// 生成一个随机 UUID v4：小写十六进制、8-4-4-4-12 分段（规格 S4 §5）。
public func newUuidV4() -> String {
    UUID().uuidString.lowercased()
}

private func nonBlank(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
