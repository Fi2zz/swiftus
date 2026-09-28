import Foundation
import SwiftusCore
import SwiftusFoundation

/// 提示词版本存档（规格 S16 §10.1）：内存为权威，可选 database 持久化
///（database 档位属 W3，本刀内存档）。
@ContextTreeActor
public final class PromptStore {
    /// 存档记录键。
    public static let key = "variants"

    private var history: [PromptVariant] = []

    public init() {}

    /// 已存档的全部版本（按创建时间升序）。
    public var all: [PromptVariant] {
        history
    }

    /// 载入存档（无持久化时为空操作）。
    public func load() async {
        // 内存存档无需载入；database 档位 W3 后补。
    }

    /// 存档一个版本（内存追加）。
    public func save(_ variant: PromptVariant) async {
        history.append(variant)
    }

    /// 按 id 查找版本；不存在返回 nil。
    public func find(_ id: String) -> PromptVariant? {
        history.first { $0.id == id }
    }
}
