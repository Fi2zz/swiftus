import Foundation
import SwiftusCore
import SwiftusCredentials
import Testing

/// S12 v1.1 的周期刷新纪律（规格 S12 §8）——时间经 `RefreshClock` 缝推进，
/// 不依赖真实墙钟。
@Suite("凭据周期刷新")
struct CredentialsRefreshTests {
    /// 让脱离调用栈的周期任务有机会跑到挂起点。
    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("周期任务至多一个：重复 load 不叠加，close 取消")
    @ContextTreeActor
    func singlePeriodicTask() async throws {
        let dir = NSTemporaryDirectory() + "s12-refresh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/creds.json"
        try "{\"K\":\"v1\"}".write(toFile: path, atomically: true, encoding: .utf8)

        let clock = ManualRefreshClock()
        let credentials = FileCredentials(path: path, refreshInterval: 60, clock: clock)
        try await credentials.load()
        // 重复 load 不叠加周期任务（挂起的等待只有一个）。
        try await credentials.load()
        try await credentials.load()
        try await settle()
        #expect(clock.pending == 1)

        // 推进一次 → 重读文件。
        try "{\"K\":\"v2\"}".write(toFile: path, atomically: true, encoding: .utf8)
        clock.advance()
        try await Task.sleep(for: .milliseconds(20))
        #expect(credentials.get("K")?.value == "v2")

        credentials.close()
        #expect(clock.pending == 0)
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test("周期路径的拉取失败静默吞掉，不打断后续调度")
    @ContextTreeActor
    func periodicFailureIsSilent() async throws {
        let clock = ManualRefreshClock()
        // 每个用例一个私有 authority：并发执行下互不串台。
        let authority = "refresh-\(UUID().uuidString).mock.local"
        let session = scriptedSession(authority: authority, body: #"{"data":{"data":{"K":"v"}}}"#)
        let credentials = VaultCredentials(
            config: VaultConfig(address: "https://\(authority)", token: "t", path: "p", refreshInterval: 30),
            session: session,
            clock: clock
        )
        try await credentials.refresh()
        try await settle()
        #expect(clock.pending == 1)

        // 周期触发时端点报错：静默吞掉，周期任务继续挂着。
        _ = scriptedSession(authority: authority, networkError: true)
        clock.advance()
        try await Task.sleep(for: .milliseconds(20))
        #expect(credentials.get("K")?.value == "v")
        #expect(clock.pending == 1)

        // 再推进一次仍然有等待者（调度未被失败打断）。
        clock.advance()
        try await Task.sleep(for: .milliseconds(20))
        #expect(clock.pending == 1)
        credentials.close()
        #expect(clock.pending == 0)
    }

    @Test("close 幂等：重复关闭不崩，快照随之关闭")
    @ContextTreeActor
    func closeIsIdempotent() async throws {
        let clock = ManualRefreshClock()
        let closeAuthority = "refresh-close-\(UUID().uuidString).mock.local"
        let credentials = AwsSecretsCredentials(
            config: AwsSecretsConfig(
                accessKey: "AKIDEXAMPLE",
                secretKey: "SECRET",
                region: "us-east-1",
                secretId: "s1",
                endpoint: "https://\(closeAuthority)/",
                refreshInterval: 10
            ),
            session: scriptedSession(authority: closeAuthority, body: #"{"SecretString":"plain"}"#),
            clock: clock,
            now: { Date(timeIntervalSince1970: 1_704_067_200) }
        )
        try await credentials.refresh()
        #expect(credentials.get("s1")?.value == "plain")
        credentials.close()
        credentials.close()
        #expect(clock.pending == 0)
        // 关闭后刷新不再改快照（快照已关，写入被忽略）。
        try? await credentials.refresh()
        #expect(credentials.get("s1")?.value == "plain")
    }

    @Test("无 refreshInterval 时不起周期任务")
    @ContextTreeActor
    func noIntervalNoTask() async throws {
        let clock = ManualRefreshClock()
        let noneAuthority = "refresh-none-\(UUID().uuidString).mock.local"
        let credentials = VaultCredentials(
            config: VaultConfig(address: "https://\(noneAuthority)", token: "t", path: "p"),
            session: scriptedSession(authority: noneAuthority, body: #"{"data":{"data":{"K":"v"}}}"#),
            clock: clock
        )
        try await credentials.refresh()
        try await settle()
        #expect(clock.pending == 0)
        #expect(clock.waits.isEmpty)
        credentials.close()
    }
}
