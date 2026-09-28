import Foundation
import SwiftusCredentials
import Testing

/// 规格 S15 §8：AWS 官方文档的签名示例做第三方交叉校验。
///
/// 这组常量**不是**从 conatus 导出的——它来自 AWS 官方《Signature Version 4
/// signing process》文档的逐步示例（GET `https://example.amazonaws.com/`，仅
/// `Host` + `X-Amz-Date: 20150830T123600Z`，空载荷）。conatus 侧 fixtures 只能
/// 证明「两端一致」，这里证明「算法与 AWS 一致」。
///
/// 纪律（见 S15 §8）：只锁定能被第三方独立实现复算出来的常量——凭记忆写下但复算
/// 不一致的向量一律丢弃，不改期望值迁就实现。移植期就撞上一次：规范请求的
/// sha256 常量记忆的尾部写错，被独立实现当场复算出来。
///
/// 断言层次：conatus 的 `sign()` **总是**把 `x-amz-content-sha256` 注入签名头，
/// 而 AWS 文档示例只签 `host;x-amz-date`，故官方向量在**原语层**断言
/// （规范请求文本 / 签名链 / 待签串 / 签名），`sign()` 的整体输出另有 conatus 形态
/// 的等价断言（见本文件末尾）。
@Suite("S15 SigV4 官方向量")
struct SigV4OfficialVectorTests {
    /// AWS 文档示例的密钥。
    private static let accessKey = "AKIDEXAMPLE"
    private static let secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    private static let emptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// AWS 文档示例的规范请求 sha256（经第三方实现复算）。
    private static let canonicalSha256 = "bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63"
    /// AWS 文档示例的最终签名（经第三方实现复算）。
    private static let signature = "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"

    @Test("规范请求六段与 AWS 文档示例逐字一致")
    func canonicalRequest() throws {
        let uri = URL(string: "https://example.amazonaws.com/")!
        let signed: [String: String] = [
            "host": "example.amazonaws.com",
            "x-amz-date": "20150830T123600Z",
        ]
        let names = signed.keys.sorted()
        let canonical = SigV4Signer.canonicalRequest(
            method: "GET",
            uri: uri,
            signed: signed,
            names: names,
            payloadHash: Self.emptySha256
        )
        #expect(canonical == """
        GET
        /

        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        \(Self.emptySha256)
        """)
        #expect(SigV4Signer.sha256Hex(canonical) == Self.canonicalSha256)
    }

    @Test("签名链四步 + 待签串 → AWS 文档示例的签名")
    func signingKeyAndStringToSign() {
        let stringToSign = """
        AWS4-HMAC-SHA256
        20150830T123600Z
        20150830/us-east-1/service/aws4_request
        \(Self.canonicalSha256)
        """
        let key = SigV4Signer.signingKey(
            secretKey: Self.secretKey,
            dateStamp: "20150830",
            region: "us-east-1",
            service: "service"
        )
        #expect(SigV4Signer.hmacHex(key: key, message: stringToSign) == Self.signature)
    }

    @Test("conatus 形态：载荷哈希参与签名时整条链也自洽")
    func conatusShapedSignature() throws {
        // 与文档示例同一请求，但把 x-amz-content-sha256 也纳入签名（conatus 的固定行为）。
        let signer = SigV4Signer(
            accessKey: Self.accessKey,
            secretKey: Self.secretKey,
            region: "us-east-1",
            service: "service"
        )
        let signed = signer.sign(
            method: "GET",
            uri: URL(string: "https://example.amazonaws.com/")!,
            headers: [:],
            payload: "",
            timestamp: try Date("2015-08-30T12:36:00Z", strategy: .iso8601)
        )
        #expect(signed["X-Amz-Date"] == "20150830T123600Z")
        #expect(signed["X-Amz-Content-Sha256"] == Self.emptySha256)
        #expect(signed["Host"] == nil)
        #expect(signed["Authorization"] == "AWS4-HMAC-SHA256 "
            + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
            + "Signature=726c5c4879a6b4ccbbd3b24edbd6b8826d34f87450fbbf4e85546fc7ba9c1642")
    }

    @Test("同输入同输出：显式时间戳让签名可复现")
    func deterministic() throws {
        let signer = SigV4Signer(
            accessKey: Self.accessKey,
            secretKey: Self.secretKey,
            region: "us-east-1",
            service: "secretsmanager"
        )
        let timestamp = try Date("2024-01-01T00:00:00Z", strategy: .iso8601)
        let uri = URL(string: "https://secretsmanager.us-east-1.amazonaws.com/")!
        let headers = ["Content-Type": "application/x-amz-json-1.1"]
        let first = signer.sign(method: "POST", uri: uri, headers: headers, payload: "{\"SecretId\":\"a\"}", timestamp: timestamp)
        let second = signer.sign(method: "POST", uri: uri, headers: headers, payload: "{\"SecretId\":\"a\"}", timestamp: timestamp)
        #expect(first == second)
        #expect(first["Authorization"]?.contains("Credential=AKIDEXAMPLE/20240101/us-east-1/secretsmanager/aws4_request") == true)
    }

    @Test("规范 URI / 查询串的边界形态与 Dart 对齐")
    func normalizationEdges() {
        func uri(_ text: String) -> URL {
            URL(string: text) ?? URL(string: "https://h/")!
        }
        // 空路径与根路径都规范为 /。
        #expect(SigV4Signer.canonicalURI(uri("https://h")) == "/")
        #expect(SigV4Signer.canonicalURI(uri("https://h/")) == "/")
        // 尾斜杠与连续斜杠是空段，原样保留。
        #expect(SigV4Signer.canonicalURI(uri("https://h/a/")) == "/a/")
        #expect(SigV4Signer.canonicalURI(uri("https://h/a//b")) == "/a//b")
        // 首空段保留。
        #expect(SigV4Signer.canonicalURI(uri("https://h//a")) == "//a")
        // 空格不二次编码；加号是字面量；非 ASCII 按 UTF-8 编码；%2F 不被解成段分隔。
        #expect(SigV4Signer.canonicalURI(uri("https://h/a%20b")) == "/a%20b")
        #expect(SigV4Signer.canonicalURI(uri("https://h/a+b")) == "/a%2Bb")
        #expect(SigV4Signer.canonicalURI(uri("https://h/%E4%B8%AD%E6%96%87")) == "/%E4%B8%AD%E6%96%87")
        #expect(SigV4Signer.canonicalURI(uri("https://h/a%2Fb")) == "/a%2Fb")
        // 查询串：整串排序、`+` 视为空格、无值键取空串、`=` 被编码。
        #expect(SigV4Signer.canonicalQuery(uri("https://h/?a=2&a=1&A=1")) == "A=1&a=1&a=2")
        #expect(SigV4Signer.canonicalQuery(uri("https://h/?flag&b=c+d&e==f")) == "b=c%20d&e=%3Df&flag=")
        #expect(SigV4Signer.canonicalQuery(uri("https://h/?b=c%2Bd")) == "b=c%2Bd")
        #expect(SigV4Signer.canonicalQuery(uri("https://h/")) == "")
    }
}
