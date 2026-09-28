import Foundation
import SwiftusAgent
import SwiftusCompaction
import SwiftusCore
import SwiftusFoundation
import SwiftusLLM
import Testing

/// 规格 S4 §6 golden fixtures：model-visible 不变式 + agent-loop 端到端。
@Suite("S4 §6 golden fixtures")
struct AgentFixtureTests {
    private static let fixtures = AgentFixtureLoader.loadAllOrEmpty()

    @Test("fixtures 已装载")
    func fixturesLoaded() {
        #expect(Self.fixtures.count >= 2)
    }

    @Test("model-visible", arguments: Self.fixtures.filter { $0.kind == "model-visible" })
    @ContextTreeActor
    func modelVisible(_ fixture: AgentFixture) throws {
        for caseItem in fixture.cases {
            let events = (caseItem["events"]?.arrayValue ?? []).map(SessionEvent.init(jsonValue:))
            let violations = checkModelVisibleInvariant(events)
            let expected = caseItem["expect"]?.objectValue?["violations"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(violations == expected, "\(caseItem["label"]?.stringValue ?? "?")")
        }
    }

    @Test("agent-loop", arguments: Self.fixtures.filter { $0.kind == "agent-loop" })
    @ContextTreeActor
    func agentLoop(_ fixture: AgentFixture) async throws {
        let expect = fixture.raw["expect"]?.objectValue ?? [:]
        let session = try Session(id: "s1")
        let log = InMemorySessionLog()
        let recorder = SessionLogRecorder(log: log)
        recorder.attach(session)
        let provider = ScriptedProvider([
            scriptedCall("c1", "add", args: #"{"a":19,"b":23}"#),
            scriptedText("19 + 23 = 42，算完了。"),
        ])
        let decorated = SessionLogLlmProvider(provider, recorder: recorder)
        let tools = ToolRegistry()
        _ = try tools.register(AddTool())
        instrumentSessionLogTools(tools, recorder: recorder)
        let loop = AgentLoop(llm: decorated, tools: tools, config: {
            var config = AgentLoop.Config()
            config.session = session
            return config
        }())
        let turn = try await loop.run(fixture.raw["input"]?.stringValue ?? "")
        try await settleLog(log, expected: 9)
        #expect(turn.reply == expect["reply"]?.stringValue)
        #expect(turn.steps.count == expect["stepCount"]?.intValue)
        #expect(session.events.map(\.type) == (expect["sessionEventTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        let events = try await log.read("s1")
        var aliases: [String: String] = [:]
        #expect(events.map { project($0, aliases: &aliases) } == (expect["log"]?.arrayValue ?? []))
        #expect(checkModelVisibleInvariant(events).isEmpty)
    }

    /// 日志条目投影（与导出器同规则：parent 先于自身 id 注册别名）。
    private func project(_ event: SessionEvent, aliases: inout [String: String]) -> JSONValue {
        var entry: [String: JSONValue] = [
            "seq": .int(Int64(event.seq)),
            "type": .string(event.type),
        ]
        if let data = event.data {
            entry["data"] = data
        }
        entry["parent"] = event.parentEventId.map { .string(alias($0, &aliases)) } ?? .null
        entry["idAlias"] = event.id.map { .string(alias($0, &aliases)) } ?? .null
        return .object(entry)
    }

    private func alias(_ id: String, _ aliases: inout [String: String]) -> String {
        if let existing = aliases[id] { return existing }
        let minted = "<evt-\(aliases.count + 1)>"
        aliases[id] = minted
        return minted
    }

    /// 等日志写入链落定到预期条数（镜像写入是后台串行链）。
    private func settleLog(_ log: any SessionLog, expected: Int) async throws {
        for _ in 0..<200 {
            if try await log.read("s1").count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("日志写入未在预期时间内落定到 \(expected) 条")
    }
}

/// get_time 工具（对齐 Dart `_timeTools`：无参数，返回固定时间）。
@ContextTreeActor
final class GetTimeTool: Tool {
    let name = "get_time"
    let description = "返回当前时间"

    func call(_ context: ToolContext) async throws -> ToolResult {
        .success("12:00")
    }
}

/// 必失败工具（对齐 Dart `_timeTools(failing: true)`）。
@ContextTreeActor
final class FailingTimeTool: Tool {
    let name = "get_time"
    let description = "返回当前时间"

    func call(_ context: ToolContext) async throws -> ToolResult {
        .failure("时钟坏了", error: ToolError("CLOCK", "broken"))
    }
}

/// 加法工具（agent-loop fixture 用；不声明 params——fixture 的 schema
/// 是 properties 空表，与导出器的 `fn` 形态对齐）。
@ContextTreeActor
final class AddTool: Tool {
    let name = "add"
    let description = "加法"

    func call(_ context: ToolContext) async throws -> ToolResult {
        guard case let .int(a) = context.arguments["a"], case let .int(b) = context.arguments["b"] else {
            return .failure("参数不合法", error: ToolError(ToolError.Codes.invalidArgs, "a/b 必填"))
        }
        return .success("\(a + b)")
    }
}

/// fixture 装载（spec/fixtures/s4 中 kind 为 model-visible / agent-loop 的文件）。
struct AgentFixture {
    let name: String
    let kind: String
    let raw: JSONValue
    let cases: [JSONValue]
}

enum AgentFixtureLoader {
    static func loadAllOrEmpty() -> [AgentFixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "spec/fixtures/s4", directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path()) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let root = try? JSONValue.parse(Data(contentsOf: directory.appending(path: name))).objectValue,
                  let kind = root["kind"]?.stringValue,
                  kind == "model-visible" || kind == "agent-loop" else {
                return nil
            }
            return AgentFixture(
                name: root["name"]?.stringValue ?? name,
                kind: kind,
                raw: .object(root),
                cases: root["cases"]?.arrayValue ?? []
            )
        }
    }
}
