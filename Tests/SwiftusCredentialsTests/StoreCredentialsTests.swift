import Foundation
import SwiftusCore
import SwiftusCredentials
import Testing

/// 规格 S12 §7.5 可插拔来源：`CredentialStore` 端口 + `StoreCredentials` 适配器。
///
/// 端口替身放在测试里（生产代码不含替身），语义全部由适配器承担。
@ContextTreeActor
@Suite("可插拔凭据来源")
struct StoreCredentialsTests {
    /// 让脱离调用栈的周期任务有机会跑到挂起点。
    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("只读 store：refresh 前为空、refresh 后入快照，update 抛 read-only")
    func readOnlyStore() async throws {
        let store = FixedStore(values: [
            "ARK_API_KEY": Credential(key: "ARK_API_KEY", value: "sk-1"),
        ])
        let credentials = StoreCredentials(store: store)
        #expect(credentials.get("ARK_API_KEY") == nil)

        try await credentials.refresh()
        #expect(credentials.get("ARK_API_KEY")?.value == "sk-1")
        #expect(credentials.keys == ["ARK_API_KEY"])

        do {
            try await credentials.update("ARK_API_KEY", "sk-2")
            Issue.record("应当抛出 read-only")
        } catch let error as CredentialsException {
            #expect(error == CredentialsException(.readOnly, "该凭据来源是只读来源。"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
        #expect(credentials.get("ARK_API_KEY")?.value == "sk-1")
    }

    @Test("可写 store：update 先落 store 再进快照并推送")
    func writableStore() async throws {
        let store = MutableStore()
        let credentials = StoreCredentials(store: store)
        try await credentials.refresh()

        var pushed: [String] = []
        credentials.addChangeListener { pushed.append($0.key) }
        try await credentials.update("DEEPSEEK_API_KEY", "sk-2")

        #expect(store.snapshot()["DEEPSEEK_API_KEY"]?.value == "sk-2")
        #expect(credentials.get("DEEPSEEK_API_KEY")?.value == "sk-2")
        #expect(pushed == ["DEEPSEEK_API_KEY"])
    }

    @Test("store 写入失败：错误透传且快照不被污染（内存不领先介质）")
    func writeFailureDoesNotPolluteSnapshot() async throws {
        let store = MutableStore(failSet: true)
        let credentials = StoreCredentials(store: store)
        try await credentials.refresh()

        do {
            try await credentials.update("K", "v")
            Issue.record("应当抛出写入错误")
        } catch let error as CredentialsException {
            #expect(error == CredentialsException(.invalidSource, "写失败"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
        #expect(credentials.get("K") == nil)
    }

    @Test("refresh 只推送新增或变化项")
    func refreshPushesOnlyChanged() async throws {
        let store = MutableStore(values: [
            "a": Credential(key: "a", value: "1"),
            "b": Credential(key: "b", value: "2"),
        ])
        let credentials = StoreCredentials(store: store)
        var pushed: [String] = []
        credentials.addChangeListener { pushed.append($0.key) }

        try await credentials.refresh()
        #expect(pushed.sorted() == ["a", "b"])

        pushed.removeAll()
        try await store.set(Credential(key: "b", value: "2b"))
        try await credentials.refresh()
        #expect(pushed == ["b"])
    }

    @Test("周期刷新至多一个，close 取消且幂等")
    func periodicRefreshAndClose() async throws {
        let clock = ManualRefreshClock()
        let store = MutableStore(values: ["K": Credential(key: "K", value: "v1")])
        let credentials = StoreCredentials(store: store, refreshInterval: 60, clock: clock)

        try await credentials.refresh()
        try await credentials.refresh()
        try await credentials.refresh()
        try await settle()
        #expect(clock.pending == 1)

        try await store.set(Credential(key: "K", value: "v2"))
        clock.advance()
        try await Task.sleep(for: .milliseconds(20))
        #expect(credentials.get("K")?.value == "v2")

        credentials.close()
        credentials.close()
        #expect(clock.pending == 0)
    }
}

/// 只读端口替身：固定表。
private struct FixedStore: CredentialStore {
    let values: [String: Credential]

    func load() async throws -> [String: Credential] {
        values
    }
}

/// 可写端口替身：内存表 + 可选的下一次写入失败。
private final class MutableStore: WritableCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Credential]
    private var failSet: Bool

    init(values: [String: Credential] = [:], failSet: Bool = false) {
        self.values = values
        self.failSet = failSet
    }

    func load() async throws -> [String: Credential] {
        readValues()
    }

    func set(_ credential: Credential) async throws {
        if let error = write(credential) {
            throw error
        }
    }

    /// 测试读取当前存储内容。
    func snapshot() -> [String: Credential] {
        readValues()
    }

    // 临界区收进同步私有方法：在 async 上下文里直接 lock/unlock 会被 strict concurrency 拒绝。
    private func readValues() -> [String: Credential] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    private func write(_ credential: Credential) -> CredentialsException? {
        lock.lock()
        defer { lock.unlock() }
        if failSet {
            failSet = false
            return CredentialsException(.invalidSource, "写失败")
        }
        values[credential.key] = credential
        return nil
    }
}
