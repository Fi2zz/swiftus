/// 上下文树的隔离域：整棵树绑定单一全局串行 actor，对应 Dart isolate 的单线程语义。
/// 域内调用全部同步；域外访问经编译期隔离检查（规格 S1/S2 实现注记）。
@globalActor
public actor ContextTreeActor {
    public static let shared = ContextTreeActor()
}

/// 域级错误兜底：Dart Zone 未捕获错误的对应物（规格 S1 实现注记）。
@ContextTreeActor
public enum ContextRuntime {
    /// 未捕获错误的上报通道；默认打印，测试可替换。
    public static var uncaughtErrorHandler: @ContextTreeActor (any Error) -> Void = { error in
        print("[swiftus] 未捕获错误：\(error)")
    }

    /// 上报一个未捕获错误（框架内部通道）。
    public static func report(_ error: any Error) {
        uncaughtErrorHandler(error)
    }
}
