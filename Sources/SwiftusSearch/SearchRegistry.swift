import Foundation
import SwiftusCore
import SwiftusCredentials

/// 搜索源装配：名字 → 凭据键 + 工厂，按顺序构造可用 provider（规格 S20 §4）。
///
/// 内置表是**数据**（`SearchProviderSpec`），新增源不改回退逻辑；构造需要凭据源与
/// HTTP 会话，两者都由装配入口注入（测试据此用 URLProtocol 桩驱动）。
public struct SearchProviderSpec: Sendable {
    /// 源名（如 `"tavily"`），用于顺序配置与显式路由。
    public let name: String
    /// 凭据键名；空串表示免 Key。
    public let credentialKey: String
    /// 用解析出的 apiKey（免 Key 源传空串）构造 provider。
    ///
    /// 工厂与 provider 同隔离域（`@ContextTreeActor`）：provider 是隔离类，隔离外构造
    /// 它就得跨越 actor 边界——这里选择让工厂也在域内。
    public let make: @ContextTreeActor @Sendable (String, SearchProviderDeps) -> any SearchProvider
}

/// provider 构造所需的依赖（规格 S20 §5）。
public struct SearchProviderDeps: Sendable {
    /// HTTP 会话（测试注入 URLProtocol 桩）。
    public let session: URLSession
    /// 单次查询超时；缺省 15 秒。
    public let timeout: TimeInterval

    public init(session: URLSession, timeout: TimeInterval = 15) {
        self.session = session
        self.timeout = timeout
    }
}

/// 内置搜索源表（规格 S20 §4：四个源，`duckduckgo` 免 Key）。
public let kSearchProviderSpecs: [String: SearchProviderSpec] = [
    "tavily": SearchProviderSpec(
        name: "tavily",
        credentialKey: kTavilyCredentialKey,
        make: { key, deps in TavilySearchProvider(apiKey: key, session: deps.session, timeout: deps.timeout) }
    ),
    "exa": SearchProviderSpec(
        name: "exa",
        credentialKey: kExaCredentialKey,
        make: { key, deps in ExaSearchProvider(apiKey: key, session: deps.session, timeout: deps.timeout) }
    ),
    "brave": SearchProviderSpec(
        name: "brave",
        credentialKey: kBraveCredentialKey,
        make: { key, deps in BraveSearchProvider(apiKey: key, session: deps.session, timeout: deps.timeout) }
    ),
    "duckduckgo": SearchProviderSpec(
        name: "duckduckgo",
        credentialKey: "",
        make: { _, deps in DuckDuckGoSearchProvider(session: deps.session, timeout: deps.timeout) }
    ),
]

/// 缺省搜索源顺序（规格 S20 §1）。
public let kDefaultSearchOrder = ["tavily", "exa", "brave", "duckduckgo"]

/// 按 `order` 构造可用 provider；缺 Key 或名字未知的源跳过并记入 statuses（规格 S20 §4）。
@ContextTreeActor
public func buildSearchProviders(
    order: [String],
    credentials: Credentials,
    session: URLSession,
    timeout: TimeInterval = 15
) -> (names: [String], providers: [any SearchProvider], statuses: [SearchSourceStatus]) {
    let deps = SearchProviderDeps(session: session, timeout: timeout)
    var names: [String] = []
    var providers: [any SearchProvider] = []
    var statuses: [SearchSourceStatus] = []
    for name in order {
        guard let spec = kSearchProviderSpecs[name] else {
            statuses.append(SearchSourceStatus(name: name, available: false, reason: "未知的搜索源"))
            continue
        }
        if !spec.credentialKey.isEmpty, credentials.get(spec.credentialKey) == nil {
            statuses.append(
                SearchSourceStatus(name: name, available: false, reason: "缺少 \(spec.credentialKey)")
            )
            continue
        }
        let key = spec.credentialKey.isEmpty ? "" : (credentials.get(spec.credentialKey)?.value ?? "")
        let provider = spec.make(key, deps)
        names.append(name)
        providers.append(provider)
        statuses.append(SearchSourceStatus(name: name, available: true))
    }
    return (names, providers, statuses)
}

/// 无凭据服务时的回退：只装配免 Key 的源，其余记「未提供凭据服务」（规格 S20 §3）。
@ContextTreeActor
public func buildKeylessSearchProviders(
    order: [String],
    session: URLSession,
    timeout: TimeInterval = 15
) -> (names: [String], providers: [any SearchProvider], statuses: [SearchSourceStatus]) {
    let deps = SearchProviderDeps(session: session, timeout: timeout)
    var names: [String] = []
    var providers: [any SearchProvider] = []
    var statuses: [SearchSourceStatus] = []
    for name in order {
        guard let spec = kSearchProviderSpecs[name], spec.credentialKey.isEmpty else {
            statuses.append(
                SearchSourceStatus(name: name, available: false, reason: "未提供凭据服务")
            )
            continue
        }
        names.append(name)
        providers.append(spec.make("", deps))
        statuses.append(SearchSourceStatus(name: name, available: true))
    }
    return (names, providers, statuses)
}
