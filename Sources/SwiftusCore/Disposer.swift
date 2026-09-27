/// 撤销函数：调用它应使系统恢复到副作用施加之前的状态。
/// 同一 Disposer 可能被多次调用（作用域释放后又手动调用），实现必须幂等（规格 S1 §1）。
public typealias Disposer = @ContextTreeActor () throws -> Void
