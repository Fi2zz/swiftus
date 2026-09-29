import Foundation
import SwiftusCore

/// provider 共用的 HTTP 细节：把请求与失败归一成 `SearchException`（规格 S20 §5）。
///
/// 统一在这里转换，使 `SearchService` 的聚合错误文案保持一致形状（`<provider>: <原因>`）。
/// **HTTP 会话由构造方注入**（测试用 `URLProtocol` 桩按 authority 分桶）。
enum SearchHttp {
    /// 发一次请求并返回响应体与状态码（非 2xx 由调用方判定，各源消息不同）。
    static func send(
        _ request: URLRequest,
        session: URLSession,
        timeout: TimeInterval,
        provider: String
    ) async throws -> (data: Data, status: Int) {
        var request = request
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch let error as URLError where error.code == .timedOut {
            throw SearchException("\(provider) 请求超时（\(Int(timeout))s）")
        } catch {
            throw SearchException("\(provider) 请求失败：\(error.localizedDescription)")
        }
    }

    /// 装配端点（测试可换主机）；解析失败抛 `SearchException`。
    static func endpoint(_ raw: String, provider: String) throws -> URL {
        guard let url = URL(string: raw) else {
            throw SearchException("\(provider) 端点非法：\(raw)")
        }
        return url
    }

    /// 拼查询项（**替换**原查询串，与来源的 `Uri.replace(queryParameters:)` 同形）。
    static func url(_ base: URL, query: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.queryItems = query
        return components.url ?? base
    }

    /// 解析响应体为 JSON 对象；非对象抛 `SearchException`。
    static func decodeObject(_ data: Data, provider: String) throws -> [String: JSONValue] {
        guard let value = try? JSONValue.parse(data), let object = value.objectValue else {
            throw SearchException("\(provider) 返回了非对象 JSON")
        }
        return object
    }

    /// 逐项投影：非对象元素跳过；缺字段按 `keys` 的候选键依次取，全缺则空串。
    static func mapResults(
        _ object: [String: JSONValue],
        container key: String = "results",
        title: String = "title",
        url urlKey: String = "url",
        snippet snippetKeys: [String] = [],
        cleanSnippet: Bool = false
    ) -> [SearchResult] {
        (object[key]?.arrayValue ?? []).compactMap { item in
            guard let row = item.objectValue else { return nil }
            var snippet = ""
            for candidate in snippetKeys {
                if let text = row[candidate]?.stringValue {
                    snippet = text
                    break
                }
            }
            return SearchResult(
                title: row[title]?.stringValue ?? "",
                url: row[urlKey]?.stringValue ?? "",
                snippet: cleanSnippet ? SearchMarkup.strip(snippet) : snippet
            )
        }
    }

    /// `clamp` 到 `1...upper`（上游条数上限）。
    static func clamp(_ value: Int, _ upper: Int) -> Int {
        Swift.min(Swift.max(1, value), upper)
    }
}
