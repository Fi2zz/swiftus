import Foundation

/// 标记清洗（规格 S20 §6）。
///
/// **snippet 会原样进入模型可见输出，故在 provider 边界统一清洗**——这是最容易被
/// 「随手重写」漂移的部分，故有独立 fixtures（`search-markup`）。
public enum SearchMarkup {
    /// 去掉标签、解常见实体并 trim（`stripMarkup`）。
    public static func strip(_ html: String) -> String {
        trim(unescape(replaceTags(html, with: "")))
    }

    /// 去掉 script/style 整块、标签换空格、解实体、压缩空白、trim（`stripHtml`）。
    public static func stripHTML(_ html: String) -> String {
        let withoutBlocks = replaceBlocks(html)
        return trim(compress(unescape(replaceTags(withoutBlocks, with: " "))))
    }

    /// 实体解码；顺序与来源一致（`&amp;` 必须先解，否则 `&amp;lt;` 会被解两次）。
    static func unescape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// 去标签。
    static func replaceTags(_ text: String, with replacement: String) -> String {
        let regex = /<[^>]+>/
        return text.replacing(regex, with: replacement)
    }

    /// 整块去掉 `<script …>…</script>` 与 `<style …>…</style>`（替换成单空格）。
    ///
    /// Dart 的 `[\s\S]` 是「任意字符」写法；Swift 用 `.` 配 `(?s)`（`.` 默认不匹配
    /// 换行）。**选项只能写在正则字面量里**——`Regex(_:options:)` 对运行期字符串没有
    /// 这个初始化器，且 `Regex(字面量)` 会退化成 `AnyRegexOutput`（捕获组只能按下标拿、
    /// 还多一层类型擦除），故全部用**裸字面量**。
    static func replaceBlocks(_ text: String) -> String {
        let script = /(?is)<script.*?<\/script>/
        let style = /(?is)<style.*?<\/style>/
        return text
            .replacing(script, with: " ")
            .replacing(style, with: " ")
    }

    /// 把连续空白压成单空格（来源只压 `[ \t\r\n]`，不含全角空格等）。
    static func compress(_ text: String) -> String {
        let regex = /[ \t\r\n]+/
        return text.replacing(regex, with: " ")
    }

    /// trim：来源的 `String.trim()` 去首尾空白。
    ///
    /// Foundation 的 `.whitespacesAndNewlines` 覆盖 Unicode 空白（含 U+2028/2029、
    /// U+00A0），比来源的 ASCII 集略宽——fixtures 的用例不含边界空白，按此保持。
    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// DuckDuckGo HTML 解析（规格 S20 §7）。
///
/// 正则在 Dart 侧是 `dotAll: true, caseSensitive: false`——Swift Regex 必须显式
/// `dotMatchesNewlines` + `.caseInsensitive`，否则跨行的 `<a>` 匹配不上（见 S20 §11）。
public enum DuckDuckGoHtml {
    /// 解析 html 端点结果：按序配对标题与摘要，空项跳过，`limit` 截断。
    public static func parse(_ html: String, limit: Int = kDefaultSearchLimit) -> [SearchResult] {
        // Dart 侧是 `dotAll: true, caseSensitive: false` → `(?is)`。
        let anchorRegex = /(?is)<a[^>]*class="result__a"[^>]*>(.*?)<\/a>/
        let snippetRegex = /(?is)<a[^>]*class="result__snippet"[^>]*>(.*?)<\/a>/
        let hrefRegex = /(?i)href="([^"]*)"/
        let anchors = Array(html.matches(of: anchorRegex))
        let snippets = Array(html.matches(of: snippetRegex))
        var results: [SearchResult] = []
        for (index, anchor) in anchors.enumerated() {
            if results.count >= limit { break }
            // 链接取**同一 `<a>` 整串**上的 href（不是全页第一个 href）。
            let whole = String(anchor.0)
            let href = (try? hrefRegex.firstMatch(in: whole)).map { String($0.1) } ?? ""
            let url = decodeHref(href)
            let title = SearchMarkup.strip(String(anchor.1))
            if url.isEmpty || title.isEmpty { continue }
            let snippet = index < snippets.count
                ? SearchMarkup.strip(String(snippets[index].1))
                : ""
            results.append(SearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// 链接解码：`//` 开头补 `https:`，再取 `uddg` 查询参数的真实链接。
    static func decodeHref(_ href: String) -> String {
        if href.isEmpty { return href }
        let absolute = href.hasPrefix("//") ? "https:\(href)" : href
        guard let components = URLComponents(string: absolute),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value else {
            return absolute
        }
        return uddg
    }
}
