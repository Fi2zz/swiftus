/// SwiftusCompaction：压缩能力缝（规格 S7）。
///
/// 把会话日志里较早的事件折叠成一条滚动摘要，服务键 `compaction`。
/// 压缩不重写日志：被折叠的事件仍在日志里，压缩只在其后追加
/// `compaction/start` / `compaction/summary` / `compaction/end` 三个记录事件。
///
/// 成员：`CompactionEngine`（契约）/ `Compactor`（默认实现）/
/// `provideCompaction`（装配）/ `balancedCutAtOrBefore` 与
/// `toolPairingBalancedBefore/After`（切点安全）/
/// `checkCompactionInvariant` 与 `assertCompactionInvariant`（日志不变式）。
