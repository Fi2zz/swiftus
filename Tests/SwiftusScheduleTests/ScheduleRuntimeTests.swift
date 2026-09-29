import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule
import Testing

/// 交付记录盒（deliver 闭包的线程安全收集）。
private actor Deliveries {
    private(set) var texts: [String] = []

    func add(_ text: String) {
        texts.append(text)
    }
}

/// 到期等待超时的失败形态。
enum ScheduleRuntimeTestError: Error, Equatable {
    case deliveryTimeout(expected: Int)
}

/// 规格 S8 §10：到期运行时（对齐 Dart `schedule_runtime_test.dart` 5 例；
/// 与 Dart 测试同策略：真实时钟 + 毫秒级短延迟）。
///
/// **等待一律有界轮询，不用固定 sleep**：Dart 侧靠测试机空闲跑过，release 优化下
/// 叠加 300+ 用例并发时 250ms 固定等待会踩空（本项目在 release 双跑时红过）。
@ContextTreeActor
@Suite("ScheduleRuntime")
struct ScheduleRuntimeTests {
    @Test("到期的提醒被交付，并写入一条派发事件；不重复交付")
    func dueDelivered() async throws {
        let session = try Session(id: "s1")
        defer { session.close() }
        try session.append(kScheduleChangeEvent, data: createPayload(
            scheduledAt: Date().addingTimeInterval(0.06)
        ))
        let deliveries = Deliveries()
        let runtime = ScheduleRuntime(
            schedule: SessionSchedule(session: session),
            deliver: { text in
                await deliveries.add(text)
                return true
            }
        )
        runtime.requestDrive()
        // 有界等待首条到达：固定 sleep 在 release / 机器负载下会踩空（本项目在
        // release 双跑时红过——60ms 的墙钟目标 + 250ms 固定等待不够稳）。
        try await waitForDeliveries(deliveries, atLeast: 1)
        #expect(await deliveries.texts.count == 1)
        #expect(await deliveries.texts.first?.contains(#"reminder_prompt_json: "到点了""#) == true)
        #expect(try foldScheduleEvents(session.ownEvents).active.isEmpty)
        #expect(changeCount(session) == 2)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await deliveries.texts.count == 1)
        await runtime.dispose()
    }

    @Test("投递被拒绝时不写派发事件，记录保持活动")
    func deferredKeepsActive() async throws {
        let session = try Session(id: "s1")
        defer { session.close() }
        try session.append(kScheduleChangeEvent, data: createPayload(
            scheduledAt: Date().addingTimeInterval(0.06)
        ))
        let runtime = ScheduleRuntime(
            schedule: SessionSchedule(session: session),
            deliver: { _ in false }
        )
        runtime.requestDrive()
        try await Task.sleep(for: .milliseconds(250))
        #expect(changeCount(session) == 1)
        #expect(try foldScheduleEvents(session.ownEvents).active.count == 1)
        await runtime.dispose()
    }

    @Test("尚未到期的提醒不会被提前交付")
    func futureNotDelivered() async throws {
        let session = try Session(id: "s1")
        defer { session.close() }
        try session.append(kScheduleChangeEvent, data: createPayload(
            scheduledAt: Date().addingTimeInterval(3600)
        ))
        let deliveries = Deliveries()
        let runtime = ScheduleRuntime(
            schedule: SessionSchedule(session: session),
            deliver: { text in
                await deliveries.add(text)
                return true
            }
        )
        runtime.requestDrive()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await deliveries.texts.isEmpty)
        #expect(changeCount(session) == 1)
        await runtime.dispose()
    }

    @Test("释放时取消等待中的定时器")
    func disposeCancelsTimer() async throws {
        let session = try Session(id: "s1")
        defer { session.close() }
        try session.append(kScheduleChangeEvent, data: createPayload(
            scheduledAt: Date().addingTimeInterval(0.08)
        ))
        let deliveries = Deliveries()
        let runtime = ScheduleRuntime(
            schedule: SessionSchedule(session: session),
            deliver: { text in
                await deliveries.add(text)
                return true
            }
        )
        runtime.requestDrive()
        await runtime.dispose()
        try await Task.sleep(for: .milliseconds(250))
        #expect(await deliveries.texts.isEmpty)
        #expect(changeCount(session) == 1)
    }

    @Test("固定间隔提醒按批次交付且只写一次决策时点")
    func everyBatchDelivered() async throws {
        let session = try Session(id: "s1")
        defer { session.close() }
        try session.append(kScheduleChangeEvent, data: .object([
            "version": .int(1),
            "operation": .string("create"),
            "schedule": .object([
                "id": .string("schedule-1"),
                "kind": .string("every"),
                "prompt": .string("检查构建"),
                "everySeconds": .int(300),
                "scheduledAt": .string(formatUtcInstant(Date().addingTimeInterval(-60))),
            ]),
        ]))
        let deliveries = Deliveries()
        let runtime = ScheduleRuntime(
            schedule: SessionSchedule(session: session),
            deliver: { text in
                await deliveries.add(text)
                return true
            }
        )
        runtime.requestDrive()
        try await waitForDeliveries(deliveries, atLeast: 1)
        #expect(await deliveries.texts.count == 1)
        #expect(await deliveries.texts.first?.contains("[SCHEDULE REMINDER BATCH]") == true)
        #expect(await deliveries.texts.first?.contains(#""reminder_prompt":"检查构建""#) == true)
        let folded = try foldScheduleEvents(session.ownEvents)
        #expect(folded.active.count == 1)
        #expect(folded.active.first.map { $0.scheduledAt > Date() } == true)
        await runtime.dispose()
    }

    /// 有界等待「至少投递了 count 条」；超时抛错（让用例失败，而不是挂死）。
    private func waitForDeliveries(
        _ deliveries: Deliveries,
        atLeast count: Int,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while await deliveries.texts.count < count {
            guard ContinuousClock.now < deadline else {
                throw ScheduleRuntimeTestError.deliveryTimeout(expected: count)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// at 一次性创建载荷。
    private func createPayload(id: String = "schedule-1", prompt: String = "到点了", scheduledAt: Date) -> JSONValue {
        .object([
            "version": .int(1),
            "operation": .string("create"),
            "schedule": .object([
                "id": .string(id),
                "kind": .string("at"),
                "prompt": .string(prompt),
                "scheduledAt": .string(formatUtcInstant(scheduledAt)),
            ]),
        ])
    }

    private func changeCount(_ session: Session) -> Int {
        session.ownEvents.filter { $0.type == kScheduleChangeEvent }.count
    }
}
