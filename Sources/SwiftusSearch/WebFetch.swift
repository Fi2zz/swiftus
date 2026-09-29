import Foundation
import SwiftusCore

/// 抓取结果的正文形态（规格 S20 §1）。
public enum FetchedFormat: String, Sendable {
    /// 剥离标签后的纯文本。
    case text
    /// 已转换的 markdown。
    case markdown
}

/// 一次抓取的结果（规格 S20 §1）。
public struct FetchedPage: Sendable, Equatable {
    /// 抓取的 URL（原样回显传入值）。
    public let url: String
    /// 正文（已按 `maxChars` 截断）。
    public let content: String
    /// 正文形态。
    public let format: FetchedFormat

    public init(url: String, content: String, format: FetchedFormat) {
        self.url = url
        self.content = content
        self.format = format
    }
}

/// 抓取失败（规格 S20 §1）：**只有消息、没有错误码**。
public struct FetchException: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

extension FetchException: CustomStringConvertible {
    /// 与来源的 `toString()` 同形。
    public var description: String {
        "FetchException: \(message)"
    }
}

/// 抓取接缝：把 URL 变成模型可读的正文（规格 S20 §1 / §8）。
@ContextTreeActor
public protocol WebFetcher: AnyObject, Sendable {
    /// 抓取 `url`，正文最多 `maxChars` 字符；失败抛 `FetchException`。
    func fetch(_ url: String, maxChars: Int) async throws -> FetchedPage
}

extension WebFetcher {
    /// 缺省正文字数（规格 S20 §1：20000）。
    public func fetch(_ url: String) async throws -> FetchedPage {
        try await fetch(url, maxChars: kFetchDefaultMaxChars)
    }
}

/// 缺省正文字数上限。
public let kFetchDefaultMaxChars = 20_000

/// 链接校验：必须是 `http` / `https` **且带主机名**（规格 S20 §8）。
func fetchValidateUrl(_ raw: String) throws -> URL {
    guard let components = URLComponents(string: raw),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host, !host.isEmpty,
          let url = components.url else {
        throw FetchException("仅支持带主机名的 http/https 链接：\"\(raw)\"")
    }
    return url
}

/// 默认抓取实现：直接 GET 并剥离 HTML 标签（规格 S20 §8）。
///
/// 覆盖到的失败形态——缺主机名或非 http(s) 的链接、请求超时、非 200 响应、传输层
/// 失败（DNS 与连接失败在 URLSession 上都表现为 `URLError`）——都归一成
/// `FetchException`，调用方只需捕获这一种异常。
@ContextTreeActor
public final class HttpFetcher: WebFetcher {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    public func fetch(_ raw: String, maxChars: Int = kFetchDefaultMaxChars) async throws -> FetchedPage {
        let url = try fetchValidateUrl(raw)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            data = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch let error as URLError where error.code == .timedOut {
            throw FetchException("请求超时（\(Int(timeout))s）")
        } catch {
            throw FetchException("抓取失败：\(error.localizedDescription)")
        }
        guard status == 200 else { throw FetchException("HTTP \(status)") }
        let text = SearchMarkup.stripHTML(String(decoding: data, as: UTF8.self))
        return FetchedPage(url: raw, content: fetchTruncate(text, maxChars), format: .text)
    }
}

/// Firecrawl 抓取后端：把网页转成 markdown（含 JS 渲染与反爬处理）（规格 S20 §8）。
///
/// 与 `HttpFetcher` 同一套链接校验与失败语义；200 但正文不是 JSON、或字段类型不符
/// （如 `markdown` 不是字符串）同样归一，调用方只需捕获 `FetchException`。
@ContextTreeActor
public final class FirecrawlFetcher: WebFetcher {
    public let apiKey: String
    private let session: URLSession
    private let endpointUrl: String
    private let timeout: TimeInterval

    public init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: String = "https://api.firecrawl.dev/v1/scrape",
        timeout: TimeInterval = 60
    ) {
        self.apiKey = apiKey
        self.session = session
        endpointUrl = endpoint
        self.timeout = timeout
    }

    public func fetch(_ raw: String, maxChars: Int = kFetchDefaultMaxChars) async throws -> FetchedPage {
        _ = try fetchValidateUrl(raw)
        var request = URLRequest(url: try SearchHttp.endpoint(endpointUrl, provider: "firecrawl"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        let payload = JSONValue.object([
            "url": .string(raw),
            "formats": .array([.string("markdown")]),
        ])
        request.httpBody = try? payload.jsonData()

        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            data = responseData
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch let error as URLError where error.code == .timedOut {
            throw FetchException("Firecrawl 请求超时（\(Int(timeout))s）")
        } catch {
            throw FetchException("抓取失败：\(error.localizedDescription)")
        }
        guard status == 200 else { throw FetchException("Firecrawl HTTP \(status)") }

        guard let value = try? JSONValue.parse(data) else {
            throw FetchException("Firecrawl 返回了非 JSON 响应")
        }
        guard let decoded = value.objectValue else {
            throw FetchException("Firecrawl 返回了非对象 JSON")
        }
        if case .bool(false) = decoded["success"] {
            let reason = decoded["error"]?.stringValue ?? "未知原因"
            throw FetchException("Firecrawl 抓取失败：\(reason)")
        }
        guard let data_ = decoded["data"]?.objectValue else {
            throw FetchException("Firecrawl 响应缺少 data")
        }
        // markdown 缺失 → 正文空串（不算失败）；存在但不是字符串 → 失败。
        var markdown = ""
        if let raw_ = data_["markdown"] {
            guard case .string(let text) = raw_ else {
                throw FetchException("Firecrawl 返回了非字符串的 markdown")
            }
            markdown = text
        }
        return FetchedPage(url: raw, content: fetchTruncate(markdown, maxChars), format: .markdown)
    }
}

/// 正文截断：超长直接切前 `maxChars` 个字符，**不加省略号**（规格 S20 §8）。
func fetchTruncate(_ text: String, _ maxChars: Int) -> String {
    text.count > maxChars ? String(text.prefix(maxChars)) : text
}
