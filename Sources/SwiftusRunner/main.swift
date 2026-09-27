import Foundation
import SwiftusCore
import SwiftusDemo

@ContextTreeActor
func runDemo() async throws {
    let scenario = try await buildDemoScenario()
    defer { scenario.context.dispose() }

    let question = "帮我算一下 19 加 23"
    print("用户:\(question)\n")
    let run = try await scenario.loop.run(question)

    for (index, step) in run.steps.enumerated() {
        for (callIndex, call) in step.toolCalls.enumerated() {
            print("第 \(index + 1) 轮 → 调用 \(call.name)(\(call.arguments))")
            print("         ← \(step.results[callIndex].content)\n")
        }
    }
    print("最终回答:\(run.answer)")
}

do {
    try await runDemo()
} catch {
    print("Demo 失败:\(error)")
    exit(1)
}
