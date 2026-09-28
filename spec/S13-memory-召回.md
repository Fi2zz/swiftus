# S13 · Memory 召回

版本：v1.0 · 日期：2026-09-28 · 来源：conatus_foundation `memory*.dart`
语言中立规格。Swiftus 实现注记见文末。
前置：S2（服务装配）、S3（事件格式）。

## 1. 词汇

- `MemoryEntry`：`{id, text, tags, createdAt}`；id 形如 `memory-<微秒>-<进程内序号>`；
- `MemoryBackend`：整表快照式存储端口——`load()` 载入全部、`save(entries)` 覆盖保存全部（便于替换为数据库或向量库）；
- `InMemoryMemoryBackend`：进程内实现（默认、不落盘）；`JsonMemoryBackend(file)`：整表写入一个 JSON 文件（父目录递归创建、flush；文件不存在 load 返回空；顶层非数组返回空；逐条目宽容反序列化）。

## 2. MemoryStore（服务键 `memory`）

`MemoryStore(maxEntries = 1000, backend = InMemoryMemoryBackend)`；maxEntries 为负快速失败。

- `entries` / `length` / `loaded`；`onChange(listener)` 返回幂等撤销（变更广播基于快照）；
- `load()`：幂等——仅首次真正读后端；读到非空时清空重建 `entries` 并广播；
- `remember(text, tags)`：**首次调用自动 load**；生成新条目入表 → 容量治理 → 后端整表保存 → 广播；返回新条目；
- `recall(query, limit = 5)`：**只看已加载的记忆**（需读盘先 load）——查询词元集为空或 limit ≤ 0 返回空；逐条与「正文 + 标签」词元集求交计数（score > 0 才入选）；按得分降序、**同分按 createdAt 新→旧**；取前 limit；
- `forget(id)`：按 id 删一条，返回是否确实删除；**首次调用自动 load**；变更后整表保存并广播；
- `forgetByText(text)`：按正文**完全一致**遗忘，返回删除条数；
- `forgetMatching(query)`：按正文**包含**（不区分大小写）遗忘；query 去空白后为空则不动，返回删除条数；
- `clear()`：全部清空（空表时不动）、整表保存并广播；
- 容量治理 `_govern`：超限时循环删 `createdAt` 最早的一条（同时间取先加入者）。

## 3. 词元化与打分

- `_tokenize(text)`：转小写后——`[a-z0-9]+` 连续段各一词元；`[\u4e00-\u9fff]+` 中文连续段按**二元组**切分（长度 1 单独成词元，否则每相邻两字一个词元，如「我喜欢」→ 「我喜」「喜欢」）；
- 打分：`queryTokens` 与 `entryTokens`（正文 + 标签拼串后词元化）的交集计数。

## 4. 装配

`provideMemory(ctx, memory?, backend?)`：服务键 `memory`，缺省 InMemoryMemoryBackend。

## 5. 有意偏离

（无。）

## Swiftus 实现注记

- `MemoryStore` 为 `@ContextTreeActor final class`；`MemoryEntry` 为 Sendable struct（jsonValue / init(jsonValue:) 往返）；`MemoryBackend` 为非隔离 async 协议（文件 IO 不占 actor）；
- 中文词元化按 `Character` 序切二元组（Swift String 的 Character 是扩展字位簇；Dart 按 UTF-16 码元——中文 BMP 内两语言对汉字切分结果一致，坑 #6 的 fixtures 用中文用例对齐）；
- `JsonMemoryBackend` 的路径参数为字符串（文件 URL 由调用方拼），写入走 JSONValue 序列化。
