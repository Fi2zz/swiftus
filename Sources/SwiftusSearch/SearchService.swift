import Foundation
import SwiftusCore

/// 搜索服务：provider 注册表 + 顺序回退（规格 S20 §2，服务键 `search`）。
///
/// **回退语义**：只有 provider **抛异常**才试下一个；**返回空列表算成功**。
@ContextTreeActor
public final class SearchService {
    private var providers: [any SearchProvider] = []
    private let statusList: [SearchSourceStatus]

    /// 装配期状态快照；**动态 `register` 不改变它**。
    public var statuses: [SearchSourceStatus] {
        statusList
    }

    public init(statuses: [SearchSourceStatus] = []) {
        statusList = statuses
    }

    /// 已注册的 provider（按注册顺序）。
    public var registeredNames: [String] {
        providers.map(\.name)
    }

    /// 已注册的 provider 实例（按注册顺序）。
    public var registered: [any SearchProvider] {
        providers
    }

    /// 注册一个 provider；返回**幂等**撤销函数。
    @discardableResult
    public func register(_ provider: any SearchProvider) -> Disposer {
        providers.append(provider)
        var removed = false
        return { [weak self] in
            guard let self, !removed else { return }
            removed = true
            self.providers.removeAll { $0 === provider }
        }
    }

    /// 查找 provider；未注册返回 nil。
    public func get(_ name: String) -> (any SearchProvider)? {
        providers.first { $0.name == name }
    }

    /// 查询：默认顺序回退；给定 `provider` 时只走该 provider（规格 S20 §2）。
    public func search(
        _ query: String,
        limit: Int = kDefaultSearchLimit,
        provider: String? = nil
    ) async throws -> [SearchResult] {
        var candidates: [any SearchProvider]
        if let provider {
            guard let found = get(provider) else {
                throw SearchException("未注册的搜索 provider \"\(provider)\"")
            }
            candidates = [found]
        } else {
            candidates = registered
        }
        guard !candidates.isEmpty else {
            throw SearchException("没有可用的搜索 provider")
        }
        var errors: [String] = []
        for candidate in candidates {
            do {
                return try await candidate.search(query, limit: limit)
            } catch {
                // 逐个源记 `<name>: <可读原因>`，全角分号连接（规格 S20 §2）。
                errors.append("\(candidate.name): \(searchErrorText(error))")
            }
        }
        throw SearchException("所有搜索 provider 都失败：\(errors.joined(separator: "；"))")
    }
}

/// 异常 → 聚合文案里的可读部分。
///
/// `SearchException` 用自身的 `description`（与来源 `toString()` 同形）；其余异常
/// 用反射描述——**跨源不可比**，故 Swift 侧只对 `SearchException` 做逐字断言。
private func searchErrorText(_ error: any Error) -> String {
    if let search = error as? SearchException { return search.description }
    if let fetch = error as? FetchException { return fetch.description }
    return String(describing: error)
}

/// 'search' 服务键。
extension ServiceKey where Service == SearchService {
    public static let search = ServiceKey<SearchService>("search")
}
