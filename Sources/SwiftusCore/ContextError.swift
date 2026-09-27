/// 上下文树相关错误；错误消息措辞与 Dart 侧保持一致（规格 S1/S2）。
import Foundation

public enum ContextError: Error, Equatable {
    /// 上下文已释放，无法再提供服务。
    case contextDisposed(key: String, context: String)
    /// 同一上下文重复提供同键服务。
    case duplicateService(key: String, context: String)
    /// 服务在上下文中不可用（含继承查找失败）。
    case serviceUnavailable(key: String, context: String)
    /// 共效应重评估在 maxRounds 轮后仍未收敛，可能存在循环依赖。
    case convergenceFailed(maxRounds: Int)
}

extension ContextError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .contextDisposed(key, context):
            "上下文 \"\(context)\" 已释放，无法再提供服务 \"\(key)\"。"
        case let .duplicateService(key, context):
            "服务 \"\(key)\" 已在上下文 \"\(context)\" 中提供。"
        case let .serviceUnavailable(key, context):
            "服务 \"\(key)\" 在上下文 \"\(context)\" 中不可用。"
        case let .convergenceFailed(maxRounds):
            "共效应重评估在 \(maxRounds) 轮后仍未收敛，"
                + "可能存在循环依赖（A 的激活依赖 B，B 的激活又依赖 A）。"
        }
    }
}
