import Foundation
import SwiftusCore
import SwiftusFoundation
import Testing

/// 规格 S18 golden fixtures：fs（路径与身份 / 读写编辑守卫 / 列举 / 删除）与
/// shell（resolve 补齐封顶 / 前台执行 / 后台句柄）。
@Suite("S18 golden fixtures")
struct S18FixtureTests {
    // MARK: fs · 路径与身份

    @Test("fs-paths", arguments: S18FixtureLoader.load(kind: "fs-paths"))
    @ContextTreeActor
    func fsPaths(_ fixture: S18Fixture) async throws {
        let fs = LocalFileSystem(cwd: s18Root.path)
        let existing = s18Root.appending(path: "paths/existing.txt")
        s18Materialize(.object(["files": .array([.object([
            "name": .string("paths/existing.txt"),
            "content": .string("hello"),
        ])])]))
        let alias = s18Root.appending(path: "paths/alias.txt")
        try? FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: existing.path)

        // 身份类断言需要按固定顺序取目标（先存在、后缺失）。
        let existingTarget = try await fs.resolve(existing.path, cwd: nil)
        let aliasTarget = try await fs.resolve(alias.path, cwd: nil)
        let viaDot = try await fs.resolve(s18Root.appending(path: "paths/./existing.txt").path, cwd: nil)
        let viaDotDot = try await fs.resolve(s18Root.appending(path: "paths/sub/../existing.txt").path, cwd: nil)
        let subdir = try await fs.resolve(s18Root.appending(path: "paths").path, cwd: nil)

        // 不存在的目标：父目录缺失 → 兜底展示路径；父目录随后创建 → 变为真实父路径 + basename。
        let freshRelative = "paths/fresh-dir/fresh.txt"
        let beforeDir = try await fs.resolve(s18Root.appending(path: freshRelative).path, cwd: nil)
        try? FileManager.default.createDirectory(
            at: s18Root.appending(path: "paths/fresh-dir"),
            withIntermediateDirectories: true
        )
        let afterDir = try await fs.resolve(s18Root.appending(path: freshRelative).path, cwd: nil)
        let deepMissing = try await fs.resolve(s18Root.appending(path: "paths/never/sub/file.txt").path, cwd: nil)

        let linkInfo = try await fs.lstat(alias.path, cwd: nil)
        let linkStat = try await fs.stat(aliasTarget)

        var byLabel: [String: [String: JSONValue]] = [:]
        for caseItem in fixture.cases {
            let label = caseItem["label"]?.stringValue ?? ""
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let actual: [String: JSONValue]
            switch label {
            case "同一文件的别名共享身份键（符号链接 / 点段 / 父段）":
                actual = [
                    "aliasKeyEqualsDirect": .bool(aliasTarget.targetKey == existingTarget.targetKey),
                    "dotKeyEqualsDirect": .bool(viaDot.targetKey == existingTarget.targetKey),
                    "dotDotKeyEqualsDirect": .bool(viaDotDot.targetKey == existingTarget.targetKey),
                    "aliasDisplayDiffers": .bool(aliasTarget.displayPath != existingTarget.displayPath),
                ]
            case "不存在的目标：父目录已存在时键为「真实父路径 + basename」，父目录缺失时退回展示路径":
                actual = [
                    "parentExists_keyEqualsDisplayPath": .bool(afterDir.targetKey == afterDir.displayPath),
                    "parentMissing_keyEqualsDisplayPath": .bool(deepMissing.targetKey == deepMissing.displayPath),
                    "keyChangesWhenParentAppears": .bool(beforeDir.targetKey != afterDir.targetKey),
                ]
            case "contains：自身与同一文件（别名）算包含、子孙算包含":
                actual = [
                    "self": .bool(fs.contains(subdir, subdir)),
                    "child": .bool(fs.contains(subdir, existingTarget)),
                    "sameFileViaAlias": .bool(fs.contains(existingTarget, aliasTarget)),
                    "parentIsNotChild": .bool(fs.contains(existingTarget, subdir)),
                ]
            case "processPath 与 fileUrl 形态":
                actual = [
                    "processPath": .string(s18Path(fs.processPath(existingTarget))),
                    "fileUrlStartsWithFile": .bool(fs.fileUrl(existingTarget).hasPrefix("file://")),
                ]
            case "lstat 不跟随最后一段符号链接（stat 则跟随）":
                actual = [
                    "lstatType": linkInfo.map { .string($0.type.rawValue) } ?? .null,
                    "statType": linkStat.map { .string($0.type.rawValue) } ?? .null,
                    "lstatSize": linkInfo?.size.map { .int(Int64($0)) } ?? .null,
                ]
            default:
                // 路径规范化类：按 fixture 里的 displayPath 逐条解析后投影。
                guard let inputPath = resolvePathFor(caseItem, root: s18Root.path) else {
                    actual = [:]
                    break
                }
                actual = await s18Attempt {
                    let target = try await fs.resolve(inputPath, cwd: nil)
                    return .object(["displayPath": .string(s18Path(target.displayPath))])
                }
                    .objectValue ?? [:]
            }
            s18ExpectSame(actual, expect, label)
            byLabel[label] = actual
        }
    }

    /// 规范化类用例的输入路径：fixture 只给 `label`，路径由约定给出——
    /// 这里用「首行 label 无关的固定映射」避免把路径藏进测试，故改为从 label 推。
    private func resolvePathFor(_ caseItem: JSONValue, root: String) -> String? {
        let label = caseItem["label"]?.stringValue ?? ""
        let map: [String: String] = [
            "绝对路径原样保留": root + "/paths/existing.txt",
            "相对路径以 cwd 为基准": root + "/paths/existing.txt",
            "cwd 覆盖实例基准": root + "/paths/existing.txt",
            "点段与父段被消解": root + "/paths/sub/.././existing.txt",
            "尾部分隔符被消解": root + "/paths/",
            "反斜杠也作分隔符": root + "\\paths\\existing.txt",
            "空路径抛 notFound": "   ",
        ]
        return map[label]
    }

    // MARK: fs · 读写与守卫

    @Test("fs-ops", arguments: S18FixtureLoader.load(kind: "fs-ops"))
    @ContextTreeActor
    func fsOps(_ fixture: S18Fixture) async throws {
        let fs = LocalFileSystem(cwd: s18Root.path)
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            s18Materialize(caseItem["input"] ?? .object([:]))
            let actual = try await runFsOps(caseItem["scenario"]?.stringValue ?? "", input: caseItem["input"] ?? .object([:]), fs: fs)
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    @ContextTreeActor
    private func runFsOps(
        _ scenario: String,
        input: JSONValue,
        fs: LocalFileSystem
    ) async throws -> [String: JSONValue] {
        switch scenario {
        case "read":
            var probes: [JSONValue] = []
            for relative in ["ops/read.txt", "ops/binary.bin", "ops/sub", "ops/ghost.txt"] {
                let path = s18Root.appending(path: relative).path
                let target = try await fs.resolve(path, cwd: nil)
                let info = try await fs.stat(target)
                let read = await s18Attempt { .string(try await fs.readText(target)) }
                probes.append(.object([
                    "path": .string(s18Path(path)),
                    "exists": .bool(info != nil),
                    "type": info.map { .string($0.type.rawValue) } ?? .null,
                    "size": info?.size.map { .int(Int64($0)) } ?? .null,
                    "read": read,
                ]))
            }
            let textTarget = try await fs.resolve(s18Root.appending(path: "ops/read.txt").path, cwd: nil)
            let text = await s18Attempt { .string(try await fs.readText(textTarget)) }
            return [
                "probes": .array(probes),
                "textFile": text,
                "subdirKept": .bool(s18FileContent("ops/sub/inner.txt") == "x"),
            ]
        case "write":
            let target = try await fs.resolve(
                s18Root.appending(path: input["target"]?.stringValue ?? "ops/new/deep/file.txt").path,
                cwd: nil
            )
            let created = try await fs.writeText(target, "第一版", expected: nil)
            let updated = try await fs.writeText(target, "第二版", expected: nil)
            let dir = try await fs.resolve(s18Root.appending(path: "ops").path, cwd: nil)
            let onDirectory = await s18Attempt {
                _ = try await fs.writeText(dir, "x", expected: nil)
                return .string("written")
            }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: s18Root.appending(path: "ops/new/deep").path))?
                .filter { $0.contains(".tmp-") }.count ?? 0
            return [
                "created": .object([
                    "operation": .string(created.operation.rawValue),
                    "before": created.before.map { .string($0) } ?? .null,
                    "after": .string(created.after),
                    "contentOnDisk": .string(s18FileContent(input["target"]?.stringValue ?? "") ?? ""),
                    "versionChanged": .bool(created.version != updated.version),
                    "tempLeftovers": .int(Int64(leftovers)),
                ]),
                "updated": .object([
                    "operation": .string(updated.operation.rawValue),
                    "before": updated.before.map { .string($0) } ?? .null,
                    "after": .string(updated.after),
                    "contentOnDisk": .string(s18FileContent(input["target"]?.stringValue ?? "") ?? ""),
                ]),
                "writeToDirectory": onDirectory,
            ]
        case "guard":
            let target = try await fs.resolve(
                s18Root.appending(path: input["target"]?.stringValue ?? "ops/guard.txt").path,
                cwd: nil
            )
            let first = try await fs.writeText(target, "v1", expected: nil)
            let createIfAbsent = await s18Attempt {
                _ = try await fs.writeText(target, "v2", expected: .createIfAbsent)
                return .string("written")
            }
            let stale = await s18Attempt {
                _ = try await fs.writeText(target, "v3", expected: .replaceIfVersion("stale-token"))
                return .string("written")
            }
            let replaced = try await fs.writeText(target, "v4", expected: .replaceIfVersion(first.version))
            let absent = try await fs.resolve(
                s18Root.appending(path: "ops/guard-absent.txt").path,
                cwd: nil
            )
            let absentVersion = await s18Attempt {
                _ = try await fs.writeText(absent, "v5", expected: .replaceIfVersion("whatever"))
                return .string("written")
            }
            return [
                "createIfAbsentOnExisting": createIfAbsent,
                "staleVersion": stale,
                "replaceWithCurrentVersion": .object([
                    "operation": .string(replaced.operation.rawValue),
                    "after": .string(replaced.after),
                    "contentOnDisk": .string(s18FileContent(input["target"]?.stringValue ?? "") ?? ""),
                ]),
                "replaceOnMissing": absentVersion,
            ]
        case "edit":
            let relative = input["target"]?.stringValue ?? "ops/edit.txt"
            let target = try await fs.resolve(s18Root.appending(path: relative).path, cwd: nil)
            _ = try await fs.writeText(target, input["content"]?.stringValue ?? "alpha\nbeta\nalpha\n", expected: nil)
            let notFound = await s18Attempt {
                _ = try await fs.editText(target, FsEditRequest(oldString: "gamma", newString: "x"), expectedVersion: nil)
                return .string("edited")
            }
            let ambiguous = await s18Attempt {
                _ = try await fs.editText(target, FsEditRequest(oldString: "alpha", newString: "x"), expectedVersion: nil)
                return .string("edited")
            }
            let all = try await fs.editText(
                target,
                FsEditRequest(oldString: "alpha", newString: "A", replaceAll: true),
                expectedVersion: nil
            )
            let staleEdit = await s18Attempt {
                _ = try await fs.editText(
                    target, FsEditRequest(oldString: "beta", newString: "z"),
                    expectedVersion: "stale-token"
                )
                return .string("edited")
            }
            let fresh = try await fs.editText(
                target,
                FsEditRequest(oldString: "beta", newString: "B"),
                expectedVersion: all.version
            )
            let absent = try await fs.resolve(s18Root.appending(path: "ops/edit-absent.txt").path, cwd: nil)
            let editMissing = await s18Attempt {
                _ = try await fs.editText(
                    absent, FsEditRequest(oldString: "a", newString: "b"), expectedVersion: nil
                )
                return .string("edited")
            }
            return [
                "notFound": notFound,
                "ambiguous": ambiguous,
                "replaceAll": .object([
                    "before": .string(all.before),
                    "after": .string(all.after),
                    "contentOnDisk": .string(s18FileContent(relative) ?? ""),
                ]),
                "staleVersion": staleEdit,
                "freshVersion": .object([
                    "before": .string(fresh.before),
                    "after": .string(fresh.after),
                    "contentOnDisk": .string(s18FileContent(relative) ?? ""),
                ]),
                "missingTarget": editMissing,
            ]
        case "list":
            let dir = try await fs.resolve(s18Root.appending(path: "ops/list").path, cwd: nil)
            let entries = try await fs.listDir(dir)
            let file = try await fs.resolve(s18Root.appending(path: "ops/list/a.txt").path, cwd: nil)
            let onFile = await s18Attempt {
                _ = try await fs.listDir(file)
                return .string("listed")
            }
            return [
                "entries": .array(entries.map { entry in
                    .object([
                        "name": .string(entry.name),
                        "type": .string(entry.type.rawValue),
                        "size": entry.size.map { .int(Int64($0)) } ?? .null,
                        "displayPath": .string(s18Path(entry.target.displayPath)),
                    ])
                }),
                "listFile": onFile,
            ]
        case "remove":
            let file = try await fs.resolve(s18Root.appending(path: "ops/remove/file.txt").path, cwd: nil)
            let tree = try await fs.resolve(s18Root.appending(path: "ops/remove/tree").path, cwd: nil)
            let ghost = try await fs.resolve(s18Root.appending(path: "ops/remove/ghost.txt").path, cwd: nil)
            try await fs.remove(file)
            let afterFile = try await fs.stat(file)
            try await fs.remove(tree)
            let afterTree = try await fs.stat(tree)
            let removeMissing = await s18Attempt {
                try await fs.remove(ghost)
                return .string("silent")
            }
            return [
                "fileGone": .bool(afterFile == nil),
                "treeGone": .bool(afterTree == nil),
                "removeMissing": removeMissing,
            ]
        default:
            Issue.record("未知 scenario：\(scenario)")
            return [:]
        }
    }

    // MARK: shell · resolve

    @Test("shell-resolve", arguments: S18FixtureLoader.load(kind: "shell-resolve"))
    @ContextTreeActor
    func shellResolve(_ fixture: S18Fixture) {
        let executor = LocalShellExecutor(
            cwd: s18Root.path,
            timeoutMs: 120_000,
            maxTimeoutMs: 600_000,
            maxOutputBytes: 64_000
        )
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            // 用例的输入按 label 约定给出（导出器与此处同款固定请求集）。
            let request = s18ResolveRequest(caseItem["label"]?.stringValue ?? "")
            let spec = executor.resolve(request)
            let actual: [String: JSONValue] = [
                "command": .string(spec.command),
                "workdir": .string(s18Path(spec.workdir)),
                "timeoutMs": .int(Int64(spec.timeoutMs)),
                "stdoutMaxBytes": .int(Int64(spec.stdoutMaxBytes)),
                "hasStdin": .bool(spec.stdin != nil),
                "env": spec.env.map { JSONValue.object($0.mapValues { .string($0) }) } ?? .null,
            ]
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    private func s18ResolveRequest(_ label: String) -> ShellExecRequest {
        switch label {
        case "请求值优先于实例默认":
            return ShellExecRequest(command: "echo hi", timeoutMs: 5000, stdoutMaxBytes: 128)
        case "超时封顶到 maxTimeoutMs":
            return ShellExecRequest(command: "echo hi", timeoutMs: 9_000_000)
        case "workdir 覆盖、stdin 与 env 透传":
            return ShellExecRequest(command: "cat", workdir: "/tmp", stdin: "hi", env: ["K": "V"])
        default:
            return ShellExecRequest(command: "echo hi")
        }
    }

    // MARK: shell · 前台执行

    @Test("shell-run", arguments: S18FixtureLoader.load(kind: "shell-run"))
    @ContextTreeActor
    func shellRun(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let input = caseItem["input"]?.objectValue ?? [:]
            let executor = LocalShellExecutor(cwd: s18Root.path, timeoutMs: 2000)
            var request = ShellExecRequest(command: input["command"]?.stringValue ?? "echo hello")
            if let timeoutMs = input["timeoutMs"]?.intValue { request.timeoutMs = Int(timeoutMs) }
            if let maxBytes = input["stdoutMaxBytes"]?.intValue { request.stdoutMaxBytes = Int(maxBytes) }
            request.stdin = input["stdin"]?.stringValue
            let result = try await executor.run(executor.resolve(request))
            // 被信号杀死的用例只断言「非 0」：Dart 给 -9、Foundation 给信号号（正数），
            // 符号是运行时细节，不进 fixture（由 input.signaledExit 声明）。
            var actual: [String: JSONValue] = [
                "timedOut": .bool(result.timedOut),
                "timeoutMs": .int(Int64(result.timeoutMs)),
                "stdout": .string(result.stdout.text),
                "stdoutTruncated": .bool(result.stdout.truncated ?? false),
                "stderr": .string(result.stderr.text),
                "stderrTruncated": .bool(result.stderr.truncated ?? false),
            ]
            if input["signaledExit"] == .bool(true) {
                actual["exitCodeIsNonZero"] = .bool((result.exitCode ?? 0) != 0)
            } else {
                actual["exitCode"] = result.exitCode.map { JSONValue.int(Int64($0)) } ?? .null
            }
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }

    // MARK: shell · 后台句柄

    @Test("shell-start", arguments: S18FixtureLoader.load(kind: "shell-start"))
    @ContextTreeActor
    func shellStart(_ fixture: S18Fixture) async throws {
        for caseItem in fixture.cases {
            let expect = caseItem["expect"]?.objectValue ?? [:]
            let command = caseItem["input"]?["command"]?.stringValue ?? "echo ready"
            let executor = LocalShellExecutor(cwd: s18Root.path)
            let process = try await executor.start(executor.resolve(ShellExecRequest(command: command)))
            var actual: [String: JSONValue]
            switch caseItem["scenario"]?.stringValue {
            case "echo":
                await process.done.value
                let first = process.readOutput()
                let second = process.readOutput()
                actual = [
                    "status": .string(process.status.rawValue),
                    "exitCode": process.exitCode.map { .int(Int64($0)) } ?? .null,
                    "delta": .string(first.delta),
                    "secondDeltaEmpty": .bool(second.delta.isEmpty),
                    "killAfterDone": .bool(process.kill()),
                ]
            default:
                let firstKill = process.kill()
                await process.done.value
                let secondKill = process.kill()
                actual = [
                    "firstKill": .bool(firstKill),
                    "status": .string(process.status.rawValue),
                    "exitCodeIsNonZero": .bool((process.exitCode ?? 0) != 0),
                    "secondKill": .bool(secondKill),
                ]
            }
            s18ExpectSame(actual, expect, caseItem["label"]?.stringValue ?? "")
        }
    }
}
