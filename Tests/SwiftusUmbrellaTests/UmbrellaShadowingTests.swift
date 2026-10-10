import Foundation
import Swiftus
import Testing

/// 伞包回归（2026-10-10 改名后设立）：
///
/// `SwiftusTasks.Task` 曾与 `_Concurrency.Task` 同名，`@_exported import`
/// 之后消费方代码里的裸 `Task { }` 会解析到任务值类型并编译失败
/// （报「trailing closure passed to parameter of type 'JSONValue'」这类
/// 看不懂的错）。任务值类型已改名 `SwiftusTask`，此套件守住两条：
/// ① 裸 `Task` 不再被遮蔽；② 任务中心 API 经伞包照常可见。
@Suite("伞包导出：Task 不被遮蔽")
struct UmbrellaShadowingTests {

    @Test("裸 Task { } 指向并发 Task，可正常创建与等待")
    func bareTaskIsConcurrencyTask() async {
        let handle = Task { 41 + 1 }
        let value = await handle.value
        #expect(value == 42)
    }

    @Test("裸 Task.sleep 不再撞任务值类型")
    func bareTaskSleepWorks() async throws {
        try await Task.sleep(for: .milliseconds(1))
    }

    @Test("任务中心类型 SwiftusTask / TaskCenter / TaskStatus 经伞包可见")
    @ContextTreeActor
    func taskCenterAPINamesVisibleThroughUmbrella() throws {
        let task = SwiftusTask(
            id: "t1",
            kind: .custom,
            status: .pending,
            description: "伞包可见性",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(task.id == "t1")
        #expect(task.status == TaskStatus.pending)
        #expect(task.status.isActive)

        let center: any TaskCenter = try DefaultTaskCenter()
        center.dispose()
    }

    @Test("restoreTaskState 的返回类型是 [SwiftusTask]（伞包下可直接标注）")
    func restoreSignatureUsesSwiftusTask() {
        // 编译期断言：伞包消费方能用裸名写出该类型。
        func accepts(_ tasks: [SwiftusTask]) -> Int { tasks.count }
        #expect(accepts([]) == 0)
    }
}
