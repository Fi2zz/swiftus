import Foundation
import SwiftusCore

/// 运行历史账本：加载、追加、状态推进与封顶（规格 S9 §7）。
///
/// 账本**惰性加载**（旧记录在前），对外列表最新在前；追加后整体封顶
/// `kCronMaxHistory` 并原子重写；`seq` 单调连续，加载时从最大 seq 续接。
@ContextTreeActor
final class CronHistoryBook {
    private let storage: any CronStorage
    private let now: @Sendable () -> Date
    private var records: [CronRunRecord] = []
    private var loaded = false
    private var seq = 0

    init(storage: any CronStorage, now: @escaping @Sendable () -> Date) {
        self.storage = storage
        self.now = now
    }

    /// 全部记录（旧记录在前）。
    var all: [CronRunRecord] {
        records
    }

    /// 预分配一个记录标识并占用 seq；交付被拒时调用 `release` 归还。
    ///
    /// **先加载账本**再分配：否则「重启后的第一次交付」会用初始 seq 0，与磁盘上
    /// 已有记录的 id 撞号（来源的 `allocateRef` 不加载，是它的缺陷——本移植修正，
    /// 见规格 S9 §11 有意偏离）。
    func allocateRef(now instant: Date) -> CronRecordRef {
        loadOnce()
        let ref = CronRecordRef(
            id: "run-\(seq)-\(radix36(Int(instant.timeIntervalSince1970 * 1000)))",
            seq: seq
        )
        seq += 1
        return ref
    }

    /// 归还最近一次分配的标识（仅当它是最新分配时生效，保持 seq 连续）。
    func release(_ ref: CronRecordRef) {
        if ref.seq == seq - 1 { seq -= 1 }
    }

    /// 追加一条记录并持久化；超帽时从头部裁剪。
    @discardableResult
    func append(_ record: CronRunRecord) -> CronRunRecord {
        loadOnce()
        records.append(record)
        if records.count > kCronMaxHistory {
            records.removeFirst(records.count - kCronMaxHistory)
        }
        persist()
        return record
    }

    /// 推进一条记录到终态；记录不存在时返回 nil。摘要截断到上限。
    func finish(_ recordId: String, ok: Bool, excerpt: String?) -> CronRunRecord? {
        loadOnce()
        for index in records.indices where records[index].id == recordId {
            records[index].status = ok ? .completed : .failed
            records[index].completedAt = now()
            records[index].excerpt = truncate(excerpt ?? records[index].excerpt)
            persist()
            return records[index]
        }
        return nil
    }

    /// 最新在前的历史列表；`limit` 非法时退化为 100，封顶 `kCronMaxHistory`。
    func list(limit: Int?) -> [CronRunRecord] {
        loadOnce()
        let cap: Int
        if let limit, limit > 0 {
            cap = min(limit, kCronMaxHistory)
        } else {
            cap = min(100, kCronMaxHistory)
        }
        return records.suffix(cap).reversed()
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        let raw = storage.loadHistory()
        records = raw.compactMap { CronRunRecord.decode($0) }
        // 从最大 seq 续接，保持单调连续。
        seq = (records.map(\.seq).max() ?? -1) + 1
    }

    private func persist() {
        storage.saveHistory(records.map { JSONValue.object($0.json) })
    }

    private func truncate(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count <= kCronExcerptLength ? text : String(text.prefix(kCronExcerptLength))
    }
}
