import Foundation
import SwiftusCore
import SwiftusFoundation

/// 提示词变体（规格 S16 §10.1）。
///
/// 一段针对特定 prompt section 的候选文本，附带生成理由、演化链上的父变体
/// 与评估得分。未评估时 score 为 nil。
public struct PromptVariant: Sendable, Equatable {
    /// 变体唯一 ID。
    public let id: String
    /// 目标 section 名。
    public let sectionName: String
    /// 变体文本。
    public let text: String
    /// 生成理由（通常为失败模式分析结果）。
    public let reason: String
    /// 父变体 ID。用于追踪演化链。
    public let parentId: String?
    /// 评估得分。未评估时为 nil。
    public let score: Double?
    /// 创建时间。
    public let createdAt: Date

    public init(
        id: String,
        sectionName: String,
        text: String,
        reason: String,
        createdAt: Date,
        parentId: String? = nil,
        score: Double? = nil
    ) {
        self.id = id
        self.sectionName = sectionName
        self.text = text
        self.reason = reason
        self.createdAt = createdAt
        self.parentId = parentId
        self.score = score
    }

    /// 复制并替换得分；传 nil 清除。
    public func withScore(_ score: Double?) -> PromptVariant {
        PromptVariant(
            id: id,
            sectionName: sectionName,
            text: text,
            reason: reason,
            createdAt: createdAt,
            parentId: parentId,
            score: score
        )
    }

    public init(jsonValue: JSONValue) {
        let object = jsonValue.objectValue ?? [:]
        id = object["id"]?.stringValue ?? ""
        sectionName = object["sectionName"]?.stringValue ?? ""
        text = object["text"]?.stringValue ?? ""
        reason = object["reason"]?.stringValue ?? ""
        createdAt = parseVariantInstant(object["createdAt"])
        parentId = object["parentId"]?.stringValue
        score = doubleOrNil(object["score"])
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "sectionName": .string(sectionName),
            "text": .string(text),
            "reason": .string(reason),
            "createdAt": .string(instantString(createdAt)),
        ]
        if let parentId {
            object["parentId"] = .string(parentId)
        }
        if let score {
            object["score"] = .double(score)
        }
        return .object(object)
    }
}

private func parseVariantInstant(_ value: JSONValue?) -> Date {
    guard let text = value?.stringValue,
          let parsed = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) else {
        return Date()
    }
    return parsed
}

private func doubleOrNil(_ value: JSONValue?) -> Double? {
    if case let .double(number) = value { return number }
    if case let .int(number) = value { return Double(number) }
    return nil
}
