import SwiftusCore
import Testing

private enum SampleError: Error {
    case boom
}

/// 规格 S1 §2:EffectScope 的 LIFO / 幂等 / 迟到登记安全 / 抗异常。
@ContextTreeActor
@Suite("EffectScope 效应语义")
struct EffectScopeTests {
    @Test("LIFO:dispose 按登记逆序执行")
    func lifoOrder() {
        let scope = EffectScope()
        var order: [Int] = []
        scope.track { order.append(1) }
        scope.track { order.append(2) }
        scope.track { order.append(3) }
        let errors = scope.dispose()
        #expect(errors.isEmpty)
        #expect(order == [3, 2, 1])
    }

    @Test("幂等:重复 dispose 只释放一次")
    func disposeIdempotent() {
        let scope = EffectScope()
        var count = 0
        scope.track { count += 1 }
        _ = scope.dispose()
        let second = scope.dispose()
        #expect(count == 1)
        #expect(second.isEmpty)
    }

    @Test("迟到登记:释放后 track 立即执行")
    func lateRegistration() {
        let scope = EffectScope()
        _ = scope.dispose()
        var ran = false
        scope.track { ran = true }
        #expect(ran)
        #expect(scope.disposed)
    }

    @Test("抗异常:单个撤销抛错不阻断其余,错误收集返回")
    func exceptionResistant() {
        let scope = EffectScope()
        var ran: [Int] = []
        scope.track { ran.append(1) }
        scope.track {
            ran.append(2)
            throw SampleError.boom
        }
        scope.track { ran.append(3) }
        let errors = scope.dispose()
        #expect(ran == [3, 2, 1])
        #expect(errors.count == 1)
    }

    @Test("capture:返回 Disposer 时自动登记,其余返回值不登记")
    func captureTracks() {
        let scope = EffectScope()
        var cleaned = 0
        scope.capture { () -> Disposer in
            { cleaned += 1 }
        }
        scope.capture { 42 }
        #expect(scope.length == 1)
        _ = scope.dispose()
        #expect(cleaned == 1)
    }
}
