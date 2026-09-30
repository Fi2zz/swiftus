import Foundation
import SwiftusCore
import SwiftusCredentials
import SwiftusFoundation
import SwiftusMCP
import Testing

/// 规格 S11 golden fixtures：配置校验与凭据占位符（mcp-config）、协议词汇
/// （mcp-protocol）、SSE 解析（mcp-sse）、内容块与结果投影（mcp-content）、
/// 风险映射与工具适配（mcp-risk）、客户端生命周期（mcp-client）、
/// 注册表生命周期（mcp-registry）。
@Suite("S11 golden fixtures")
struct S11FixtureTests {

    // MARK: mcp-config · 配置校验与凭据占位符

    @Test("mcp-config", arguments: S11FixtureLoader.names(kind: "mcp-config"))
    @ContextTreeActor
    func config(_ name: String) async throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            switch scenario {
            case "validate":
                let inputs = caseItem["input"]?.arrayValue ?? []
                let expects = caseItem["expect"]?.arrayValue ?? []
                #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(inputs, expects) {
                    // fixture 的每条是 `{label, input: {…}}` 两层。
                    let spec = input["input"]?.objectValue ?? [:]
                    let got: JSONValue
                    do {
                        let config = try McpServerConfig(
                            name: spec["name"]?.stringValue ?? "",
                            type: mcpFixtureTransportType(spec["type"]?.stringValue ?? ""),
                            command: spec["command"]?.stringValue,
                            args: (spec["args"]?.arrayValue ?? []).compactMap(\.stringValue),
                            env: mcpFixtureStringMap(spec["env"]),
                            url: spec["url"]?.stringValue,
                            headers: mcpFixtureStringMap(spec["headers"])
                        )
                        got = .object([
                            "name": .string(config.name),
                            "type": .string(config.type.rawValue),
                            "command": config.command.map { .string($0) } ?? .null,
                            "args": .array(config.args.map { .string($0) }),
                            "env": .object(config.env.mapValues { .string($0) }),
                            "url": config.url.map { .string($0) } ?? .null,
                            "headers": .object(config.headers.mapValues { .string($0) }),
                        ])
                    } catch let error as McpConfigError {
                        got = .object(["invalid": .object([
                            "name": .string(error.name),
                            "message": .string(error.message),
                        ])])
                    }
                    mcpExpectValue(got, expect, "\(label)：\(spec["label"]?.stringValue ?? "")", counter: counter)
                }
            case "placeholders":
                let values = mcpFixtureStringMap(caseItem["input"]?["values"])
                let seeded = mcpFixtureStringMap(caseItem["input"]?["credentials"])
                let credentials = InMemoryCredentials()
                for (key, value) in seeded {
                    try await credentials.update(key, value)
                }
                let expect = caseItem["expect"]?.objectValue ?? [:]
                let withCreds = resolveCredentialPlaceholders(values, credentials)
                // 无凭据服务时占位符原样保留（Swift 字符串里 `\${` 不是合法转义，
                // 故按 `$` + `{KEY}` 拼出来，语义与 fixture 输入逐字相同）。
                let rawPlaceholder = "$" + "{REMOTE_TOKEN}"
                let withoutCreds = resolveCredentialPlaceholders(["header": "Bearer " + rawPlaceholder], nil)
                let full: [String: JSONValue] = [
                    "withCredentials": .object(withCreds.mapValues { .string($0) }),
                    "withoutCredentials": .object(withoutCreds.mapValues { .string($0) }),
                ]
                mcpExpectSame(mcpProjectKeys(full, caseItem["expect"] ?? .null), expect, label, counter: counter)
            default:
                Issue.record("未知的 S11 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }

    // MARK: mcp-protocol · 协议词汇

    @Test("mcp-protocol", arguments: S11FixtureLoader.names(kind: "mcp-protocol"))
    func protocolVocabulary(_ name: String) throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let inputs = caseItem["input"]?.arrayValue ?? []
            let expects = caseItem["expect"]?.arrayValue ?? []
            switch scenario {
            case "message":
                #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(inputs, expects) {
                    // fixture 的每条是 `{label, json: {…}}` 两层。
                    let message = McpMessage(json: input["json"]?.objectValue ?? [:])
                    let full: [String: JSONValue] = [
                        "request": .bool(message.isRequest),
                        "notification": .bool(message.isNotification),
                        "response": .bool(message.isResponse),
                        "toJson": .object(message.json),
                    ]
                    mcpExpectSame(mcpProjectKeys(full, expect), expect.objectValue ?? [:], "\(label)：\(input["label"]?.stringValue ?? "")", counter: counter)
                }
            case "handshake":
                #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(inputs, expects) {
                    // fixture 的每条是 `{label, json: {…}}` 两层。
                    let info = McpServerInfo(json: input["json"]?.objectValue ?? [:])
                    let full: [String: JSONValue] = [
                        "protocolVersion": .string(info.protocolVersion),
                        "name": info.name.map { .string($0) } ?? .null,
                        "version": info.version.map { .string($0) } ?? .null,
                        "instructions": info.instructions.map { .string($0) } ?? .null,
                        "capabilities": .object(info.capabilities),
                    ]
                    mcpExpectSame(mcpProjectKeys(full, expect), expect.objectValue ?? [:], "\(label)：\(input["label"]?.stringValue ?? "")", counter: counter)
                }
            case "const":
                // 唯一保留来源侧 `toString` 原貌的用例：`McpException(code): message`
                // 是纯格式规则、歧义为零（见 exporter README 的 S11 段）。
                let full: [String: JSONValue] = [
                    "protocolVersion": .string(kMcpProtocolVersion),
                    "toolName": .string(mcpToolName("fs", "read_file")),
                    "exception": .string(McpException("timeout", "示例").description),
                ]
                mcpExpectSame(mcpProjectKeys(full, caseItem["expect"] ?? .null), expects.first?.objectValue ?? [:], label, counter: counter)
            default:
                Issue.record("未知的 S11 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }

    // MARK: mcp-sse · SSE 解析

    @Test("mcp-sse", arguments: S11FixtureLoader.names(kind: "mcp-sse"))
    func sse(_ name: String) throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            guard caseItem["scenario"]?.stringValue == "parse" else { continue }
            let label = caseItem["label"]?.stringValue ?? ""
            let cases = caseItem["input"]?.arrayValue ?? []
            let expects = caseItem["expect"]?.arrayValue ?? []
            #expect(cases.count == expects.count, "「\(label)」输入与期望数量应一致")
            for (input, expect) in zip(cases, expects) {
                let chunks = (input["chunks"]?.arrayValue ?? []).compactMap(\.stringValue)
                let events = mcpParseSseChunks(chunks)
                mcpExpectValue(.array(events), expect, "\(label)：\(input["label"]?.stringValue ?? "")", counter: counter)
            }
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }

    // MARK: mcp-content · 内容块与结果投影

    @Test("mcp-content", arguments: S11FixtureLoader.names(kind: "mcp-content"))
    func content(_ name: String) throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let inputs = caseItem["input"]?.arrayValue ?? []
            let expects = caseItem["expect"]?.arrayValue ?? []
            switch scenario {
            case "result":
                #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(inputs, expects) {
                    // fixture 的每条是 `{label, json: {…}}` 两层。
                    let result = toolResultFromMcp(McpToolResult(json: input["json"]?.objectValue ?? [:]))
                    let full: [String: JSONValue] = [
                        "text": .string(result.content),
                        "failed": .bool(result.failed),
                        "code": result.error.map { .string($0.code) } ?? .null,
                        "value": result.value ?? .null,
                    ]
                    mcpExpectSame(mcpProjectKeys(full, expect), expect.objectValue ?? [:], "\(label)：\(input["label"]?.stringValue ?? "")", counter: counter)
                }
            case "describe":
                #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(inputs, expects) {
                    let blocks = (input["blocks"]?.arrayValue ?? []).compactMap { $0.objectValue }.map(McpContent.init(json:))
                    mcpExpectValue(.string(describeMcpContent(blocks)), expect, "\(label)：\(input["label"]?.stringValue ?? "")", counter: counter)
                }
            default:
                Issue.record("未知的 S11 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }

    // MARK: mcp-risk · 风险映射与工具适配

    @Test("mcp-risk", arguments: S11FixtureLoader.names(kind: "mcp-risk"))
    @ContextTreeActor
    func risk(_ name: String) async throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let inputs = caseItem["input"]?.arrayValue ?? []
            let expects = caseItem["expect"]?.arrayValue ?? []
            switch scenario {
            case "risk":
                #expect(inputs.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(inputs, expects) {
                    // fixture 的每条是 `{label, json: {…}}` 两层。
                    let tool = McpTool(json: input["json"]?.objectValue ?? [:])
                    mcpExpectValue(
                        .string(mcpToolRisk(tool).label),
                        expect,
                        "\(label)：\(input["label"]?.stringValue ?? "")",
                        counter: counter
                    )
                }
            case "schema":
                let server = caseItem["input"]?["server"]?.stringValue ?? ""
                // 工具列表在 `input.tools` 里（顶层 `input` 是 `{server, tools}`）。
                let tools = caseItem["input"]?["tools"]?.arrayValue ?? []
                #expect(tools.count == expects.count, "「\(label)」输入与期望数量应一致")
                for (input, expect) in zip(tools, expects) {
                    // fixture 的每条是 `{label, json: {…}}` 两层。
                    let tool = McpTool(json: input["json"]?.objectValue ?? [:])
                    let adapter = McpToolAdapter(
                        client: McpClient(transport: DeadMcpTransport(), serverName: server),
                        tool: tool
                    )
                    let full: [String: JSONValue] = [
                        "name": .string(adapter.name),
                        "description": .string(adapter.description),
                        "risk": .string(adapter.riskLevel.label),
                        "group": adapter.group.map { .string($0) } ?? .null,
                        // 入参声明留空：`ParamSpec` 表达不了任意 JSON Schema（规格 S11 §7）。
                        "params": .array(adapter.params.map { .string($0.name) }),
                        "schema": adapter.schema,
                    ]
                    mcpExpectSame(mcpProjectKeys(full, expect), expect.objectValue ?? [:], "\(label)：\(input["label"]?.stringValue ?? "")", counter: counter)
                }
            default:
                Issue.record("未知的 S11 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }

    // MARK: mcp-client · 客户端生命周期

    @Test("mcp-client", arguments: S11FixtureLoader.names(kind: "mcp-client"))
    @ContextTreeActor
    func client(_ name: String) async throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            let scenario = caseItem["scenario"]?.stringValue ?? ""
            let label = caseItem["label"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]
            switch scenario {
            case "happy":
                let spec = caseItem["input"]?.objectValue ?? [:]
                let server = spec["serverName"]?.stringValue ?? "fs"
                let transport = ScriptedMcpTransport()
                transport.initialize = spec["initializeResult"]?.objectValue ?? [:]
                transport.pages = (spec["pages"]?.arrayValue ?? []).map { $0 }
                transport.callResult = spec["callResult"]?.objectValue ?? [:]
                let client = McpClient(transport: transport, serverName: server)

                let info = try await client.initialize()
                let tools = try await client.listTools()
                let called = try await client.callTool("read_file", ["path": .string("/tmp/a")])
                let readyAfterInit = client.ready
                let sent = transport.sentLabels
                await client.close()
                let readyAfterClose = client.ready
                // close 幂等：第二次调用不应抛。
                await client.close()

                let full: [String: JSONValue] = [
                    "serverInfo": .object([
                        "protocolVersion": .string(info.protocolVersion),
                        "name": info.name.map { .string($0) } ?? .null,
                        "version": info.version.map { .string($0) } ?? .null,
                    ]),
                    "ready": .bool(readyAfterInit),
                    "tools": .array(tools.map { tool in
                        .object(["name": .string(tool.name), "risk": .string(mcpToolRisk(tool).label)])
                    }),
                    "callText": .string(describeMcpContent(called.content)),
                    "callFailed": .bool(called.failed),
                    "callValue": called.structuredContent.map { JSONValue.object($0) } ?? .null,
                    "sent": .array(sent.map { .string($0) }),
                    "readyAfterClose": .bool(readyAfterClose),
                    "closedTwice": .bool(true),
                ]
                mcpExpectSame(mcpProjectKeys(full, .object(expect)), expect, label, counter: counter)
            case "errors":
                let spec = caseItem["input"]?.objectValue ?? [:]
                let timeoutMs = spec["timeoutMs"]?.intValue ?? 5

                // 翻页超限：服务端每页都回同一个游标。
                let looping = ScriptedMcpTransport()
                looping.pages = [.object([
                    "tools": .array([.object(["name": .string("a")])]),
                    "nextCursor": .string(spec["loopingCursor"]?.stringValue ?? "always-more"),
                ])]
                let loopClient = McpClient(transport: looping, serverName: "loop")
                try await loopClient.initialize()
                let tooManyPages = await mcpFixtureGuard { _ = try await loopClient.listTools() }
                await loopClient.close()

                // 协议错误：响应带 error 对象。
                let erroring = ScriptedMcpTransport()
                erroring.initializeError = spec["initializeError"]?.objectValue
                let errClient = McpClient(transport: erroring, serverName: "err")
                let protocolError = await mcpFixtureGuard { _ = try await errClient.initialize() }
                await errClient.close()

                // result 畸形：第二页回一个非对象 result。
                let malformed = ScriptedMcpTransport()
                malformed.pages = [
                    .object(["tools": .array([]), "nextCursor": .string("c2")]),
                    .string(spec["malformedPage"]?.stringValue ?? "不是对象"),
                ]
                let malClient = McpClient(transport: malformed, serverName: "mal")
                try await malClient.initialize()
                let malformedResult = await mcpFixtureGuard { _ = try await malClient.listTools() }
                await malClient.close()

                // 超时：服务端对 tools/list 不回应。
                let driver = McpManualTimerDriver()
                let silent = ScriptedMcpTransport()
                silent.silentMethods = ["tools/list"]
                let timeoutClient = McpClient(
                    transport: silent,
                    serverName: "slow",
                    timeout: .milliseconds(timeoutMs),
                    driver: driver
                )
                try await timeoutClient.initialize()
                let timeoutTask = Task { try await timeoutClient.listTools() }
                try await mcpAwaitSent(silent, "tools/list")
                // 手动推进时间缝：不依赖真实墙钟。
                for _ in 0..<10 where !timeoutTask.isCancelled {
                    driver.advance(.milliseconds(timeoutMs))
                    try? await Task.sleep(for: .milliseconds(2))
                }
                let timeout = await mcpFixtureGuard { _ = try await timeoutTask.value }
                await timeoutClient.close()

                // 断连：连接级故障 → 在账请求判 disconnected，断连信号一次。
                let dying = ScriptedMcpTransport()
                dying.silentMethods = ["tools/list"]
                let disconnectClient = McpClient(transport: dying, serverName: "dying")
                try await disconnectClient.initialize()
                let signalBox = McpSignalCounter()
                disconnectClient.onDisconnect = { _ in signalBox.hit() }
                let pendingTask = Task { try await disconnectClient.listTools() }
                try await mcpAwaitSent(dying, "tools/list")
                let cause = spec["disconnectCause"]?.objectValue ?? [:]
                dying.fail(McpException(
                    cause["code"]?.stringValue ?? "server-exited",
                    cause["message"]?.stringValue ?? "子进程退出"
                ))
                let disconnect = await mcpFixtureGuard { _ = try await pendingTask.value }
                await disconnectClient.close()
                let disconnectCase: [String: JSONValue] = [
                    "pending": disconnect,
                    "disconnectSignals": .int(Int64(signalBox.total)),
                    "ready": .bool(disconnectClient.ready),
                ]
                mcpExpectSame(
                    mcpProjectKeys(disconnectCase, expect["disconnect"] ?? .null),
                    expect["disconnect"]?.objectValue ?? [:],
                    "\(label)：断连",
                    counter: counter
                )

                // close 之后剩余待办判 closed。
                let holding = ScriptedMcpTransport()
                holding.silentMethods = ["tools/list"]
                // 注入手动时间缝：超时计时器永不自行到点，于是「close 判 closed」
                // 不与「超时」竞态（否则这条用例要真等 30s，且结果取决于调度顺序）。
                let closingClient = McpClient(
                    transport: holding,
                    serverName: "hold",
                    driver: McpManualTimerDriver()
                )
                try await closingClient.initialize()
                let closingTask = Task { try await closingClient.listTools() }
                try await mcpAwaitSent(holding, "tools/list")
                await closingClient.close()
                let closed = await mcpFixtureGuard { _ = try await closingTask.value }

                let errors: [String: JSONValue] = [
                    "tooManyPages": tooManyPages,
                    "protocolError": protocolError,
                    "malformedResult": malformedResult,
                    "timeout": timeout,
                    "disconnect": .object(disconnectCase),
                    "closed": closed,
                ]
                mcpExpectSame(mcpProjectKeys(errors, .object(expect)), expect, label, counter: counter)
            default:
                Issue.record("未知的 S11 scenario：\(scenario)")
            }
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }

    // MARK: mcp-registry · 注册表生命周期

    @Test("mcp-registry", arguments: S11FixtureLoader.names(kind: "mcp-registry"))
    @ContextTreeActor
    func registry(_ name: String) async throws {
        let fixture = try #require(S11FixtureLoader.load(named: name), "找不到 fixture：\(name)")
        let counter = McpAssertionCounter()
        for caseItem in fixture.cases {
            guard caseItem["scenario"]?.stringValue == "lifecycle" else { continue }
            let label = caseItem["label"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]

            let context = Context.root()
            let tools = try provideTools(context)
            let registry = McpRegistry()

            func makeClient(_ server: String, connectFails: Bool = false) -> (McpClient, ScriptedMcpTransport) {
                let transport = ScriptedMcpTransport()
                transport.connectError = connectFails ? McpException("not-connected", "连不上 \(server)") : nil
                transport.pages = [.object([
                    "tools": .array([
                        .object(["name": .string("read_file"), "description": .string("\(server) 的 read_file")]),
                        .object(["name": .string("write_file"), "riskLevel": .string("destructive")]),
                    ]),
                ])]
                transport.callResult = ["content": .array([
                    .object(["type": .string("text"), "text": .string("\(server):ok")]),
                ])]
                return (McpClient(transport: transport, serverName: server), transport)
            }

            let (fsClient, fsTransport) = makeClient("fs")
            try await registry.attach(context, fsClient)
            let (gitClient, _) = makeClient("git")
            try await registry.attach(context, gitClient)

            let afterAttach: [String: JSONValue] = [
                "servers": .array(registry.servers.map { .string($0) }),
                "tools": .array(tools.names.map { .string($0) }),
                "groups": .object(mcpToolProjection(tools, "group")),
                "risks": .object(mcpToolProjection(tools, "risk")),
                "fsToolCount": .int(Int64(registry.tools(of: "fs").count)),
                "clientOfMissing": .bool(registry.client(of: "nope") != nil),
            ]
            mcpExpectSame(
                mcpProjectKeys(afterAttach, expect["afterAttach"] ?? .null),
                expect["afterAttach"]?.objectValue ?? [:],
                "\(label)：装配后",
                counter: counter
            )

            // 装配一台连不上的 server：不上账（不留半死条目）。
            let (brokenClient, _) = makeClient("broken", connectFails: true)
            let attachFailure = await mcpFixtureGuard { try await registry.attach(context, brokenClient) }

            // 断连一台：只注销它的工具，另一台照常。
            fsTransport.fail(McpException("server-exited", "子进程退出"))
            await mcpFixtureSettle()
            let afterDrop: [String: JSONValue] = [
                "servers": .array(registry.servers.map { .string($0) }),
                "tools": .array(tools.names.map { .string($0) }),
            ]
            mcpExpectSame(
                mcpProjectKeys(afterDrop, expect["afterDrop"] ?? .null),
                expect["afterDrop"]?.objectValue ?? [:],
                "\(label)：断连后",
                counter: counter
            )

            // 短别名。
            try registry.addAlias(context, "read_file", "git__read_file")
            let alias = tools.get("read_file")
            let afterAlias: [String: JSONValue] = [
                "tools": .array(tools.names.map { .string($0) }),
                "aliasDescription": alias.map { .string($0.description) } ?? .null,
                "aliasGroup": alias?.group.map { .string($0) } ?? .null,
                "aliasRisk": alias.map { .string($0.riskLevel.label) } ?? .null,
                "aliasSchemaName": alias?.schema["name"] ?? .null,
            ]
            mcpExpectSame(
                mcpProjectKeys(afterAlias, expect["afterAlias"] ?? .null),
                expect["afterAlias"]?.objectValue ?? [:],
                "\(label)：短别名",
                counter: counter
            )
            let aliasMissing = await mcpFixtureGuard {
                try registry.addAlias(context, "nope", "missing__tool")
            }
            let aliasClash = await mcpFixtureGuard {
                try registry.addAlias(context, "git__read_file", "git__read_file")
            }
            let (duplicateClient, _) = makeClient("git")
            let duplicate = await mcpFixtureGuard {
                try await registry.attach(context, duplicateClient)
            }
            for (key, value) in [
                "attachFailure": attachFailure,
                "aliasMissing": aliasMissing,
                "aliasClash": aliasClash,
                "duplicate": duplicate,
            ] {
                mcpExpectValue(value, expect[key] ?? .null, "\(label)：\(key)", counter: counter)
            }

            // 全部关闭：幂等。
            await registry.close()
            await registry.close()
            let afterClose: [String: JSONValue] = [
                "servers": .array(registry.servers.map { .string($0) }),
                "tools": .array(tools.names.map { .string($0) }),
            ]
            mcpExpectSame(
                mcpProjectKeys(afterClose, expect["afterClose"] ?? .null),
                expect["afterClose"]?.objectValue ?? [:],
                "\(label)：关闭后",
                counter: counter
            )

            // 上下文释放：撤销句柄幂等，不应抛。
            let other = Context.root()
            let otherTools = try provideTools(other)
            let (lateClient, _) = makeClient("late")
            try await registry.attach(other, lateClient)
            let registeredBefore = otherTools.names.count
            other.dispose()
            // `dispose()` 幂等且不抛：第二次释放不应崩（撤销句柄契约，规格 S1 §1）。
            other.dispose()
            let disposeFailure: JSONValue = .null
            let contextDispose: [String: JSONValue] = [
                "registeredBefore": .int(Int64(registeredBefore)),
                "registeredAfter": .int(Int64(otherTools.names.count)),
                "secondDisposeFailed": disposeFailure,
            ]
            mcpExpectSame(
                mcpProjectKeys(contextDispose, expect["contextDispose"] ?? .null),
                expect["contextDispose"]?.objectValue ?? [:],
                "\(label)：上下文释放",
                counter: counter
            )
            context.dispose()
        }
        #expect(counter.total > 0, "「\(name)」一条都没比对（vacuously passing）")
    }
}

// MARK: - 助手

/// 尽力执行并把异常收敛成 `{error: {code, message}}` / `{state: …}` / `{invalid: …}`。
@ContextTreeActor
func mcpFixtureGuard(_ body: @ContextTreeActor () async throws -> Void) async -> JSONValue {
    do {
        try await body()
        return .string("ok")
    } catch let error as McpException {
        return .object(["error": .object([
            "code": .string(error.code),
            // 断连消息里嵌着来源侧异常的渲染形态，两端统一归一（见 exporter README
            // 的 S11 段）：锁「断连原因整段透传」，不锁异常类名。
            "message": .string(mcpFixtureNormalize(error.message)),
        ])])
    } catch let error as McpConfigError {
        return .object(["invalid": .object([
            "name": .string(error.name),
            "message": .string(error.message),
        ])])
    } catch let error as McpRegistryError {
        return .object(["state": .string(error.description)])
    } catch let error as ToolRegistryError {
        return .object(["state": .string("工具 \"\(mcpFixtureName(of: error))\" 已注册")])
    } catch {
        return .object(["unexpected": .string("\(error)")])
    }
}

/// 取出 `ToolRegistryError.duplicate` 里的工具名。
func mcpFixtureName(of error: ToolRegistryError) -> String {
    if case let .duplicate(name) = error { return name }
    return ""
}

/// 与导出器 `_normalize` 同形：把 `McpException(code): ` 归一成 `mcp-error(code): `。
func mcpFixtureNormalize(_ message: String) -> String {
    // 用扩展定界符 `#/…/#`：模式里有裸 `/`，裸字面量会被提前截断。
    message.replacing(#/McpException\(([^)]+)\): /#) { match in
        "mcp-error(\(match.output.1)): "
    }
}

func mcpFixtureTransportType(_ raw: String) -> McpTransportType {
    McpTransportType(rawValue: raw) ?? .stdio
}

func mcpFixtureStringMap(_ value: JSONValue?) -> [String: String] {
    (value?.objectValue ?? [:]).compactMapValues(\.stringValue)
}

/// 逐块喂 SSE 解析器（切分方式与 fixture 的 `chunks` 一致）。
func mcpParseSseChunks(_ chunks: [String]) -> [JSONValue] {
    var parser = McpSseParser()
    var state = McpSseParser.State()
    var events: [SseEvent] = []
    for chunk in chunks {
        events += parser.consume(Array(chunk.utf8), state: &state)
    }
    events += parser.finish(&state)
    return events.map { event in
        .object([
            "event": event.event.map { .string($0) } ?? .null,
            "data": .string(event.data),
            "id": event.id.map { .string($0) } ?? .null,
        ])
    }
}

@ContextTreeActor
func mcpToolProjection(_ registry: ToolRegistry, _ field: String) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for name in registry.names {
        guard let tool = registry.get(name) else { continue }
        out[name] = field == "group"
            ? tool.group.map { .string($0) } ?? .null
            : .string(tool.riskLevel.label)
    }
    return out
}

/// 断连计数（断连信号必须**只**触发一次）。
final class McpSignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func hit() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// 有界轮询：等传输真的收到某个方法的请求。
///
/// `Task { client.listTools() }` 到真正发出之间没有同步点，紧接着的 `close()`
/// / `fail()` 可能跑在它前面——那时待办表还是空的，`failAll` 扑空，请求就永久
/// 悬挂（这正是 `closed` 用例最初挂死的原因）。**有界轮询，不固定 sleep**
/// （见坑 #8：release + 全量并发下固定 sleep 会踩空）。
@ContextTreeActor
func mcpAwaitSent(_ transport: ScriptedMcpTransport, _ method: String, rounds: Int = 50) async throws {
    for _ in 0..<rounds {
        if transport.sentLabels.contains(method) { return }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("等待「\(method)」请求发出超时（\(rounds) 轮）")
}

/// 让微任务队列跑完（断连信号是异步投递的）。
///
/// **有界轮询，不固定 sleep**（见坑 #8：release + 全量并发下固定 sleep 会踩空）。
@ContextTreeActor
func mcpFixtureSettle(rounds: Int = 20) async {
    for _ in 0..<rounds {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// 永不连上的传输：只为投影 schema / 描述，不发起任何调用。
@ContextTreeActor
final class DeadMcpTransport: McpTransport {
    private let sink = McpMessageSink()
    private let diagnostics = McpDiagnostics()

    func connect() async throws {}

    func disconnect() async {
        sink.finish()
        diagnostics.dispose()
    }

    func messages() -> AsyncStream<McpTransportEvent> {
        sink.stream()
    }

    @discardableResult
    func observeDiagnostics(_ body: @escaping @Sendable (String) -> Void) -> Int {
        diagnostics.observe(body)
    }

    func send(_ message: McpMessage) async throws {
        throw McpException("not-connected", "仅用于投影")
    }
}
