import SwiftusCore
import Testing

/// 规格 S1 §3:Reactor 的广播 / 重入脏标记 / 快照遍历 / 非收敛快速失败。
@ContextTreeActor
@Suite("Reactor 反应器")
struct ReactorTests {
    @Test("基本广播:登记的监听器被同步回调")
    func basicBroadcast() throws {
        let reactor = Reactor()
        var runs = 0
        reactor.add { runs += 1 }
        try reactor.notify()
        #expect(runs == 1)
        #expect(reactor.length == 1)
    }

    @Test("重入:广播中再 notify 仅置脏标记,外层重跑至收敛")
    func reentrantNotify() throws {
        let reactor = Reactor()
        var firstRuns = 0
        var secondRuns = 0
        reactor.add {
            firstRuns += 1
            if firstRuns == 1 {
                try? reactor.notify()
            }
        }
        reactor.add { secondRuns += 1 }
        try reactor.notify()
        #expect(firstRuns == 2)
        #expect(secondRuns == 2)
        #expect(!reactor.running)
    }

    @Test("快照遍历:回调中新增监听器本轮不生效")
    func snapshotIteration() throws {
        let reactor = Reactor()
        var addedRuns = 0
        var installed = false
        reactor.add {
            guard !installed else { return }
            installed = true
            reactor.add { addedRuns += 1 }
        }
        try reactor.notify()
        #expect(addedRuns == 0)
        try reactor.notify()
        #expect(addedRuns == 1)
    }

    @Test("非收敛:超过 maxRounds 轮抛 convergenceFailed")
    func nonConvergenceThrows() {
        let reactor = Reactor(maxRounds: 3)
        var runs = 0
        reactor.add {
            runs += 1
            try? reactor.notify()
        }
        #expect(throws: ContextError.convergenceFailed(maxRounds: 3)) {
            try reactor.notify()
        }
        #expect(runs == 3)
    }

    @Test("remove:移除后不再回调,重复移除返回 false")
    func removeToken() throws {
        let reactor = Reactor()
        var runs = 0
        let token = reactor.add { runs += 1 }
        #expect(reactor.remove(token))
        #expect(!reactor.remove(token))
        try reactor.notify()
        #expect(runs == 0)
    }
}
