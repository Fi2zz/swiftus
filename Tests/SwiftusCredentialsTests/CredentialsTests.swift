import Foundation
import SwiftusCore
import SwiftusCredentials
import Testing

/// 规格 S12:快照语义、env / memory 来源、契约错误、解析口径、脱敏。
@ContextTreeActor
@Suite("凭据快照与来源")
struct CredentialsTests {
    @Test("快照:get 过期即无;update 写入并推送")
    func snapshotGetAndUpdate() {
        let snapshot = CredentialSnapshot()
        let past = Date().addingTimeInterval(-3600)
        let future = Date().addingTimeInterval(3600)
        #expect(snapshot.get("missing") == nil)
        snapshot.update(Credential(key: "k", value: "v", expiresAt: past))
        #expect(snapshot.get("k") == nil)

        var pushed: [String] = []
        snapshot.addChangeListener { pushed.append($0.key) }
        snapshot.update(Credential(key: "k", value: "v2", expiresAt: future))
        #expect(snapshot.get("k")?.value == "v2")
        #expect(pushed == ["k"])
    }

    @Test("refreshSnapshot:只推送新增或变化,移除不推送")
    func refreshPushesChanged() {
        let snapshot = CredentialSnapshot()
        snapshot.update(Credential(key: "a", value: "1"))
        snapshot.update(Credential(key: "b", value: "2"))
        var pushed: [String] = []
        snapshot.addChangeListener { pushed.append($0.key) }
        snapshot.refreshSnapshot([
            "a": Credential(key: "a", value: "1"),
            "b": Credential(key: "b", value: "2b"),
            "c": Credential(key: "c", value: "3"),
        ])
        #expect(pushed.sorted() == ["b", "c"])
        #expect(snapshot.keys.sorted() == ["a", "b", "c"])
    }

    @Test("close 幂等且关闭后写入被忽略")
    func closeIgnores() {
        let snapshot = CredentialSnapshot()
        snapshot.close()
        snapshot.close()
        snapshot.update(Credential(key: "a", value: "1"))
        #expect(snapshot.keys.isEmpty)
        #expect(snapshot.closed)
    }

    @Test("InMemory:update 立即生效并推送,initial 建快照")
    func inMemory() async throws {
        let credentials = InMemoryCredentials(initial: ["ARK_API_KEY": "sk-1"])
        #expect(credentials.get("ARK_API_KEY")?.value == "sk-1")
        var pushed: [String] = []
        credentials.addChangeListener { pushed.append($0.key) }
        try await credentials.update("DEEPSEEK_API_KEY", "sk-2")
        #expect(credentials.get("DEEPSEEK_API_KEY")?.value == "sk-2")
        #expect(pushed == ["DEEPSEEK_API_KEY"])
    }

    @Test("Env:非空值入快照,update 抛 read-only")
    func env() async {
        let credentials = EnvCredentials(environment: ["A": "1", "B": ""])
        #expect(credentials.get("A")?.value == "1")
        #expect(credentials.get("B") == nil)
        do {
            try await credentials.update("A", "2")
            Issue.record("应当抛出 read-only")
        } catch let error as CredentialsException {
            #expect(error == CredentialsException(.readOnly, "环境变量凭据是只读来源。"))
        } catch {
            Issue.record("错误类型不对:\(error)")
        }
    }

    @Test("require / validate 错误消息")
    func requireValidate() {
        let credentials = InMemoryCredentials(initial: ["a": "1"])
        #expect(throws: CredentialsException(.missing, "缺少凭据 \"b\"。")) {
            try credentials.require("b")
        }
        #expect(throws: CredentialsException(.missing, "缺少凭据：b, c")) {
            try credentials.validate(["a", "b", "c"])
        }
    }

    @Test("parseCredentialMap:字符串直取、对象形态、非法项跳过")
    func parseMap() {
        let parsed = parseCredentialMap(.object([
            "plain": .string("v1"),
            "timed": .object(["value": .string("v2"), "expiresAt": .string("2030-01-01T00:00:00Z")]),
            "bad_number": .int(42),
            "bad_object": .object(["noValue": .string("x")]),
        ]))
        #expect(parsed.count == 2)
        #expect(parsed["plain"]?.value == "v1")
        #expect(parsed["timed"]?.expiresAt != nil)
        #expect(parseCredentialMap(.array([])).isEmpty)
    }

    @Test("Credential:masked 与 description 不含明文")
    func maskedDescription() {
        let credential = Credential(key: "k", value: "sk-1234567890")
        #expect(credential.masked == "sk-1...7890")
        #expect(!credential.description.contains("sk-1234567890"))
        #expect(!credential.expired())
    }
}
