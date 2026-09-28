import Foundation
import SwiftusCore
import SwiftusFoundation
import SwiftusSchedule

/// 把到期提醒接到自主运营的 deliver 端口（规格 S16 §8.4）：空闲时后台触发
/// 一轮 AutonomousRunner.run，返回 true；已在运行返回 false（不写 dispatch，
/// 记录保持活动、下次重试）。
///
/// 单轮失败经 onError 上报（缺省静默——失败已记入审计/遥测，若装配），
/// 不会中断后续调度。
@ContextTreeActor
public func autonomousDelivery(
    _ runner: any AutonomousRunner,
    onError: (@ContextTreeActor (any Error) -> Void)? = nil
) -> ScheduleDelivery {
    { text in
        guard !runner.isRunning else { return false }
        Task {
            do {
                _ = try await runner.run()
            } catch {
                onError?(error)
            }
        }
        return true
    }
}

/// 把自主运营定时启动装配进上下文（规格 S16 §8.4，服务键 'autonomousSchedule'）。
///
/// 依赖 'schedule' 服务（provideSessionSchedule），未显式传入 schedule 时从
/// 上下文解析。自驱动：任何 schedule/change 事件落盘都会触发重新推导；装配时
/// 立即推导一次。不占用 'scheduleRuntime' 服务键，可与宿主自己的到期投递并存。
@ContextTreeActor
@discardableResult
public func provideAutonomousSchedule(
    _ ctx: Context,
    runner: any AutonomousRunner,
    schedule: SessionSchedule? = nil,
    onError: (@ContextTreeActor (any Error) -> Void)? = nil
) throws -> ScheduleRuntime {
    let resolvedSchedule = try schedule ?? ctx.require(.schedule)
    let runtime = ScheduleRuntime(
        schedule: resolvedSchedule,
        deliver: autonomousDelivery(runner, onError: onError)
    )
    try ctx.provide(.autonomousSchedule, runtime)
    ctx.onDispose {
        Task { await runtime.dispose() }
    }
    let off = resolvedSchedule.session.onEvent { event in
        if event.type == kScheduleChangeEvent {
            runtime.requestDrive()
        }
    }
    ctx.onDispose {
        try? off()
    }
    runtime.requestDrive()
    return runtime
}

/// 'autonomousSchedule' 服务键。
extension ServiceKey where Service == ScheduleRuntime {
    public static let autonomousSchedule = ServiceKey<ScheduleRuntime>("autonomousSchedule")
}
