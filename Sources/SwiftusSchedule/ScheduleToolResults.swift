import Foundation
import SwiftusCore
import SwiftusFoundation

/// 提醒工具的统一结果形状（规格 S8 §11.2）。
///
/// 工具结果对模型是规范 JSON 文本：成功时是记录视图或视图数组，失败时是
/// `{code, message}`。错误码取自封闭集合 ScheduleErrorCode。

/// 成功结果：规范值同时作为文本与结构化值返回。
func scheduleSuccessResult(_ value: JSONValue) -> ToolResult {
    let text = (try? value.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    return .success(text, value: value)
}

/// 失败结果：文本是 {code, message} 的 JSON，错误码透传给宿主。
func scheduleErrorResult(_ code: ScheduleErrorCode, _ message: String) -> ToolResult {
    let payload = JSONValue.object(["code": .string(code.rawValue), "message": .string(message)])
    let text = (try? payload.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? code.rawValue
    return .failure(text, error: ToolError(code.rawValue, message))
}

/// 持久化不确定的失败结果；调用方应先用 schedule_list 澄清。
func schedulePersistenceResult(_ error: SchedulePersistenceError) -> ToolResult {
    scheduleErrorResult(
        .persistenceUncertain,
        "Schedule persistence is uncertain; retry with schedule_list before relying on this result."
    )
}

/// 持久日志损坏的失败结果；具体不变式只用于日志，不暴露给模型。
func scheduleCorruptResult() -> ToolResult {
    scheduleErrorResult(.corruptLog, "The session schedule log is corrupt.")
}

/// 不暴露内部细节的兜底失败结果。
func scheduleInternalResult() -> ToolResult {
    scheduleErrorResult(.internalError, "The schedule operation failed.")
}

/// 异常 → 失败结果映射（规格 S8 §11.2）：输入错误透传、持久化不确定固定文案、
/// 日志损坏隐藏细节、其余兜底。
func scheduleFailureResult(_ error: any Error) -> ToolResult {
    if let input = error as? ScheduleInputError {
        return scheduleErrorResult(input.code, input.message)
    }
    if let persistence = error as? SchedulePersistenceError {
        return schedulePersistenceResult(persistence)
    }
    if error is ScheduleLogError {
        return scheduleCorruptResult()
    }
    return scheduleInternalResult()
}
