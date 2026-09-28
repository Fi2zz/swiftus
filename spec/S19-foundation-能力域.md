# S19 · Foundation 能力域（database / timer / time-context / logger / loader）

版本：v1.0 · 日期：2026-09-28 · 来源：conatus_foundation `database*.dart` / `timer.dart` / `time_context.dart` / `logger_console.dart` / `loader.dart`
语言中立规格。Swiftus 实现注记见文末。
前置：S2（上下文树与可逆效应）、S5/S6（工具与 Prompt 装配，供 time-context 引用）。
范围说明：S18 的姊妹篇。五个域各自独立、互不依赖，共享两条纪律：**时间只走注入缝**、**配置载荷只走 JSON**。不含 Windows 分支（AGENTS 已定不移植）。

## 1. Database

### 1.1 词汇

- 错误码（`DatabaseException.code`）：`invalid-backend` / `duplicate-backend` / `backend-not-found` / `invalid-unit` / `already-open` / `no-backend` / `unit-closed` / `malformed-medium`；
- `DatabaseBackend`（服务键 `database` 上的注册项，名字由注册方给定）：`load(unit) -> 整表`（**单元不存在返回空表**）、`save(unit, records)`（**整表覆盖**）、`deleteUnit(unit)`、`close()`（幂等）。每次调用都是原子的，返回即已落盘；**后端不负责并发排序**（由 §1.3 的写入链保证）；
- `DatabaseChange = {unit, key, kind(put|deleted), value?}`：`put` 带新值，`deleted` 的 `value` 为空；
- `Database`（KV hub，本身**不做 IO**）：后端注册表 + 已打开单元表；
- `DatabaseUnit`（单元句柄）：**权威内存状态 + 写入链 + 变更广播**。

### 1.2 Database（hub）

- `backendNames`：已注册后端名（**注册顺序**）；`units`：已打开单元名（**打开顺序**）；`length`：已打开单元数；
- `register(name, backend)`：空名抛 `invalid-backend`、重名抛 `duplicate-backend`（消息 `后端 "<name>" 已注册`）；返回**撤销函数**（幂等，且只在「当前注册的仍是同一后端」时真正移除——被同名重注册后旧撤销函数不得误删新后端）；
- `backend(name)`：未注册抛 `backend-not-found`；
- `open(unit, backend?)`：空名抛 `invalid-unit`、已打开抛 `already-open`（消息 `单元 "<unit>" 已打开`）；后端路由 = 显式名 > `defaultBackend` > **仅一个已注册后端**；仍不能定则抛 `no-backend`（`未指定后端且注册的后端不唯一`）。载入整表后返回句柄，**句柄关闭时从表里摘除**；
- `get(unit)`：未打开返回空；`close(unit)`：返回是否确实关闭了一个（未打开返回 false）；`closeAll()`：关闭全部（幂等）；
- 装配：以 `database` 服务键提供；随上下文释放 `closeAll`。

### 1.3 DatabaseUnit（单元句柄）

- `name` / `closed` / `length`（记录条数）/ `keys`（快照）/ `has(key)`（**值为空也算存在**）/ `get(key)`（不存在返回空）/ `entries()`（全表只读快照）；
- **写入链顺序**（关键不变式）：`put` / `delete` 先把**下一版整表**交给后端落盘 → **成功后才更新内存** → 成功后才广播 `DatabaseChange`。因此**读到的内存状态永不领先于介质**，后端写失败时内存保持不变、异常原样上抛；
- `put(key, value)`：已关闭抛 `unit-closed`（`单元 "<name>" 已关闭`）；值可为 null；
- `delete(key)`：不存在返回 **false 且不落盘、不广播**；已关闭同上；
- `onChange(listener)`：返回撤销函数（幂等）；
- `close()`：幂等；置 `closed`、**清空监听器**、从 hub 表摘除。

### 1.4 本地 JSON 后端

- 每单元一个人类可读的 JSON 文件（`<dir>/<unit>.json`），整表 `jsonEncode` 后**临时文件 + rename 原子发布**（rename 失败退化为直接写并清理临时文件），父目录递归创建；
- `load`：文件不存在返回空表；内容**不是 JSON 对象**抛 `malformed-medium`；
- 单元名必须是安全文件名：**空或含路径分隔符（`/` `\`）抛 `invalid-unit`**（`非法单元名 "<unit>"`）；
- 缺省目录为 `<swiftus home>/database`；
- 装配：注册到 hub（名缺省 `json`），随上下文释放**撤销注册并关闭后端**。

## 2. timer

全部定时器都登记在**调用方上下文**上（可逆效应），随上下文释放自动清理；也可用返回的撤销函数提前取消。**时间只走注入缝**（见实现注记）。

- `timeout(callback, delay)`：延迟后执行一次；返回撤销函数；
- `interval(callback, delay)`：每 delay 执行一次；返回撤销函数；
- `sleep(delay)`：等待 delay。**上下文在到点前被释放时，等待以错误结束**（`上下文 "<name>" 已释放，sleep 被中断。`），避免调用方悬挂；
- `throttle(callback, delay, trailing = true)`：窗口内重复调用**最多执行一次**。`trailing` 为真时**被抑制的调用在窗口结束时补执行一次**（并重置窗口），为假时直接丢弃。首次调用立即执行；
- `debounce(callback, delay)`：最后一次调用后静默 delay 才执行；`call()` **重置计时**；`dispose()` 取消挂起中的执行并停用（幂等）；
- 两种包装的 `dispose` 都**幂等**，且停用后再 `call()` **不执行**；
- 撤销函数与 `dispose` 都登记在上下文上（`throttle` / `debounce` 本身也由上下文 track）。

## 3. time-context

模型没有时钟，相对日期（"明天""下周三"）与带本地语义的时刻（"明早九点"）都需要外部锚点。本域把**日粒度的当前日期**注册为一份动态 Prompt 上下文，每轮装配重新求值（跨天自动更新）。

- 常量：上下文名 `time`、排序权重 `-10`（靠前）；
- 锚点文本：`[当前时间]\n<YYYY-MM-DD> 周<一|二|三|四|五|六|日> · <时区> (UTC<±HH:MM>)`；
- **时区名与时区偏移相互独立**：`zoneName` 只是**显示名覆盖**（可传 IANA 名，缺省用时刻自身时区的缩写）；**偏移与日历字段（年/月/日/星期）一律取时刻自身时区**。故「名字写 Asia/Shanghai 但偏移是 +00:00」是完全合法的组合（Dart 行为如此，fixtures 即如此）；
- 时区偏移格式化为 `±HH:MM`（如 `+08:00`、`-05:30`，半小时时区正确补零）；
- 锚点**只精确到日**：不输出时分秒（见下条）；
- 时刻源与时区均为注入项；默认取系统当前时刻与本地时区。

## 4. logger

内核不带 logger，本域自带日志服务并默认挂控制台导出器。

- `LogLevel`：`debug`(0) / `info`(1) / `warn`(2) / `error`(3)，**严重度递增**；
- `LogRecord = {level, name, message, time, error?, stackTrace?}`；
- `LoggerService`（服务键 `logger`）：`defaultName`（直接用服务方法记录时的名字）、`level`（全局最小级别，**低于它的日志被丢弃**）、`recentLimit`（最近日志环形保留上限，缺省 100）、`exporters`（只读副本）、`recent`（只读副本）、`logger(name?)`（缺省用 `defaultName`）、`addExporter` / `removeExporter`（返回是否确实移除了**同一实例**）、`debug/info/warn/error`（以 `defaultName` 记录）；
- **记录顺序**：过级别 → 建记录 → 进环形缓冲（超限丢最旧）→ 依次交给各导出器（按登记顺序，快照遍历）；
- 命名 `Logger` 门面：`name` + 四个级别方法，转发到服务；
- `ConsoleExporter`：`writer`（写一整行，缺省 stdout）、`level`（**导出器自身**的级别过滤，空表示不过滤）、`showTime`（行首输出 ISO 时间）；行格式 `[<D|I|W|E>] <name><两空格><message>`，`error` 非空时**追加一个空格后再写 error**；`stackTrace` 非空时**另起一行**写出；
- 装配：以 `logger` 服务键提供；挂控制台导出器时随上下文释放**移除该导出器**。

## 5. loader

Dart 没有动态 `import()`，loader 用**注册表**代替模块解析：宿主先 `register(name, factory)`，再用配置树声明要加载哪些插件。

- `LoaderEntry = {id?, name?, config?, disabled = false, children = []}`：**`name` 为空即分组节点**（自身不加载插件，只承载子节点）；`id` 缺省由 loader 生成；
- `LoaderEntry` 支持 JSON 反序列化与序列化（`disabled` 为假不出现，空子节点不出现，`config` 为空不出现）；
- `Loader`（服务键 `loader`）：注册表 `register`（空名抛错；**同名覆盖**）/ `unregister`（返回是否确实移除）/ `has` / `names`；配置树 `ids`（**加载顺序**）/ `isEmpty` / `contextOf(id)`（未加载或未运行时为空）/ `entryOf(id)` / `apply(entries)`（**先卸载全部现有 entry（逆序）再逐个加载**）/ `applyJson` / `load(entry, parent?)`（返回 id，分组递归子节点）/ `remove(id)`（卸载该 entry **及其所有后代**，按 `id` 或 `id:` 前缀匹配，逆序卸载；未知 id 抛错）/ `reload(id)`（**分组与禁用项不重启**）；
- **id 生成**：`entry-<序号>`（全局自增），有父时为 `<父id>:entry-<序号>`；
- `load` 的失败语义：id 已存在抛 `entry "<id>" 已存在`（**先登记再校验插件**，失败时把该 id 从表里摘掉）；未注册插件抛 `未注册的插件 "<name>"（entry "<id>"）`并摘掉该 id；**分组节点即使没有对应工厂也照常登记**（它不加载插件）；
- **工厂本身抛错时**：子上下文按 S2 §4 回滚（已登记的撤销函数照跑，异常继续上抛），但 **entry 仍留在表里**（Dart 侧同样如此——只有「未注册插件」才摘 id），本规格照实记录；
- 已加载的 entry 都是**装载器上下文的子上下文**，随宿主上下文释放而自动卸载；
- 装配：以 `loader` 服务键提供，可选预注册插件并立即 `apply(config)`。

## 6. 有意偏离

- **`message` 的类型**：Dart 的 `LogRecord.message` 是任意对象（隐式 `toString`），本规格定为字符串（模型侧的日志载荷本就以文本进入；非文本值由调用方先转文本）；
- **`LoaderEntry.config` 的类型**：Dart 是任意 Dart 对象，本规格定为 JSON 值（与全项目「动态 JSON 走 `JSONValue`」的纪律一致，见实现注记）；
- **Dart 的 `Object?` 表即 JSON 表**：Dart 的 `Map<String, Object?>` 允许混入非 JSON 值，落地时一律转 JSON；不可编码的值退化为字符串是语言相关的展示面，不入 fixtures；
- **`dispose` 与 `closeAll` 的异步性**：Dart 的 `Database.closeAll` 是 `Future`；本移植在装配处登记上下文释放回调，同步收口（单元关闭本身是同步的）；
- **timer 的时钟**：Dart 直接读 `DateTime.now()` / `Timer`；本移植全部经注入的时间缝（见下），语义等价但可测。

## Swiftus 实现注记

- 五域全部 `@ContextTreeActor`（与仓库既有纪律一致：跨域服务不引非 Sendable 悬空引用）；`DatabaseBackend` / `LogExporter` 等端口显式标 `: Sendable`（S17 记录的「global actor 协议的 existential 不自动 Sendable」坑）；
- **时间缝**：`timer` 域注入 `TimerDriver`（`wait(_:)` 可取消的等待 + `now()` 供 throttle 算窗口），生产实现走 `Task.sleep` + `ContinuousClock`，测试注入可手动推进的受控驱动；`time-context` 注入 `(时刻, 时区)`；`logger` 注入 `now`。**任何模块都不直接读系统时钟**（AGENTS）；
- `Database` 的写入链按 §1.3 落：`Task` 内先 `await` 后端落盘，成功后回 actor 更新内存并广播——落盘在 actor 外（IO 不串行），内存与广播严格在 actor 内，天然满足「内存不领先介质」；
- 广播一律**同步监听列表 + 撤销令牌**（同 S12 `CredentialSnapshot`），不用流：消费方与来源同域，无跨线程时序差异；
- `DatabaseUnit.entries` 返回**值拷贝**（Swift 字典是值类型，天然不可变），比 Dart 的 `unmodifiable` 视图更严格但语义一致；
- `Loader` 的 `PluginFactory` 定为 `@ContextTreeActor (Context, JSONValue?) -> Void`，子上下文用 Core 的 `ctx.plugin(_:install:)`（install 抛错自动回滚，S2 §4）；
- `time-context` 的星期与补零用固定中文表与显式 pad（不引 `DateFormatter` 的 locale 推断，避免宿主 locale 影响输出）；时区偏移取 `TimeZone.secondsFromGMT(for:)`，半小时时区按分钟补零；
- `logger` 的控制台导出器默认写 `stdout`（`print`，单行）；测试注入收集闭包；
- `TimerDriver.wait` 的取消语义：抛 `CancellationError` 表示被撤销，周期任务据此收尾（与 S12 `RefreshClock` 同款纪律）；
- **fixtures 不锁时间**：`timer` 域只投影**计数与是否发生**（触发过几次、撤销后是否还触发、sleep 是否被中断），不投影具体间隔；节流/防抖的窗口边界由 Swift 侧受控驱动断言；
- **非零时区偏移的日期换算不进 fixtures**：Dart 侧只有 UTC 偏移能确定性构造（`DateTime.parse` 带偏移会归一到 UTC，`toLocal()` 依赖运行机器的本地时区），故 fixtures 的渲染类用例固定 UTC 时刻；**非零偏移下的日期 / 星期换算**与「本地时区缩写」由 Swift 侧单元测试用注入的偏移断言（偏移在 Swift 侧是纯注入项，能表达任意值）；
- **秒级不进锚点**：`system` 是可缓存前缀，秒级变化会让缓存每轮失效，因此锚点只到日。
