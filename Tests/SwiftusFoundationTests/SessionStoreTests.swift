import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S4：持久化与日志的边界语义（fixtures 未覆盖的部分）。
@ContextTreeActor
@Suite("Session 持久化边界")
struct SessionStoreTests {
    @Test("同 id 重复创建/adopt 抛 duplicateSession；close 未打开返回 false")
    func duplicateAndClose() throws {
        let store = SessionStore()
        try store.create(id: "s1")
        #expect(throws: SessionStoreError.duplicateSession("s1")) {
            try store.create(id: "s1")
        }
        #expect(store.close("ghost") == false)
        #expect(store.close("s1") == true)
        #expect(store.get("s1") == nil)
    }

    @Test("open 无持久化时开空会话；重复 open 返回同一活跃实例")
    func openWithoutPersistence() async throws {
        let store = SessionStore()
        let session = try await store.open("s1")
        #expect(session.length == 0)
        #expect(try await store.open("s1") === session)
        #expect(try await store.persistedIds() == [])
    }

    @Test("flush 无在途写入时立即返回；写入失败由 flush 暴露且不毒化后续写入")
    func flushExposesFirstFailure() async throws {
        let dir = NSTemporaryDirectory() + "s4-flush-\(UUID().uuidString)"
        let persistence = try JsonlSessionPersistence(directory: dir + "/blocked")
        // 用一个会先失败（目录被文件占位）后恢复的端口验证链不卡住
        let flaky = FlakyPersistence(inner: persistence)
        let store = SessionStore(persistence: flaky)
        let session = try store.create(id: "s1")
        await flaky.failNext()
        try session.append("e0")
        try session.append("e1")
        await #expect(throws: FlakyError.self) {
            try await store.flush()
        }
        // 第二次 flush：首个错误已暴露并清空；e0 写入失败被丢弃，e1 已落定（失败不毒化后续写入）
        try await store.flush()
        #expect(try await persistence.load("s1").map(\.type) == ["e1"])
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("装配：显式 log 优先，persistence 次之，缺省内存；persistence 服务复用")
    func providePriorities() throws {
        let ctx = Context.root()
        let memoryLog = InMemorySessionLog()
        try provideSessionLog(ctx, log: memoryLog)
        #expect(try ctx.require(.sessionLog) as AnyObject === memoryLog)
        ctx.dispose()

        let dir = NSTemporaryDirectory() + "s4-provide-\(UUID().uuidString)"
        let ctx2 = Context.root()
        try provideSessionPersistence(ctx2, persistence: try JsonlSessionPersistence(directory: dir))
        let log2 = try provideSessionLog(ctx2)
        #expect(log2 is PersistenceSessionLog)
        ctx2.dispose()

        let ctx3 = Context.root()
        #expect(try provideSessionLog(ctx3) is InMemorySessionLog)
        ctx3.dispose()
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("InMemorySessionLog：缺 sessionId 抛 invalid_event；fork 不存在事件抛 event_not_found；close 幂等清空")
    func memoryLogEdges() async throws {
        let log = InMemorySessionLog()
        await #expect(throws: SessionLogError(code: "invalid_event", message: "SessionLog 要求事件带非空 sessionId")) {
            try await log.append(SessionEvent(seq: 0, type: "x", time: Date()))
        }
        await #expect(throws: SessionLogError.self) {
            try await log.fork("s1", fromEventId: "ghost")
        }
        log.close()
        log.close()
        #expect(log.closed)
        #expect(log.list() == [])
    }

    @Test("家目录解析：SWIFTUS_HOME 覆盖优先，缺 HOME 快速失败，uuid 形状")
    func homeResolution() throws {
        #expect(try resolveSwiftusHome(env: ["SWIFTUS_HOME": "/tmp/custom"]) == "/tmp/custom")
        #expect(try resolveSwiftusHome(env: ["HOME": "/Users/x"]) == "/Users/x/.swiftus")
        #expect(throws: HomeError.homeUnavailable) {
            try resolveHomeDir(env: [:])
        }
        let uuid = newUuidV4()
        #expect(uuid.wholeMatch(of: /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/) != nil)
    }
}

/// 注入失败的持久化包装（flush 语义验证用）。
private actor FlakyPersistence: SessionPersistence {
    private let inner: JsonlSessionPersistence
    private var failing = false

    init(inner: JsonlSessionPersistence) {
        self.inner = inner
    }

    func failNext() {
        failing = true
    }

    func list() async throws -> [String] {
        try await inner.list()
    }

    func load(_ id: String) async throws -> [SessionEvent] {
        try await inner.load(id)
    }

    func append(_ id: String, _ event: SessionEvent) async throws {
        if failing {
            failing = false
            throw FlakyError()
        }
        try await inner.append(id, event)
    }

    func remove(_ id: String) async throws {
        try await inner.remove(id)
    }
}

private struct FlakyError: Error {}
