# S18 · Foundation 能力域（fs / shell）

版本：v1.0 · 日期：2026-09-28 · 来源：conatus_foundation `fs*.dart` / `shell*.dart`
语言中立规格。Swiftus 实现注记见文末。
前置：S2（服务装配）、S5（工具管线，供 approval 路径引用）、S17（shell 任务的追踪装饰器）。
范围说明：文件系统的**目标身份 + 原子写入 + 字面编辑 + 陈旧守卫**，与命令执行的**有界输出 + 前台超时 + 后台句柄**。两域都是能力缝：端口在本规格，实现分本地后端（fs 本地 / shell 本地）与可注入替身。**不含** Windows 分支（AGENTS 已定不移植）。

## 1. 文件系统词汇

- 错误码（`FsError.code` → 线上字符串）：`notFound` / `notDirectory` / `notText` / `notRegularFile` / `tooLarge` / `permissionDenied` / `sandboxDenied` / `ioError` / `staleVersion` / `notObserved` / `ambiguousEdit` / `editNotFound` / `aborted`；形如 `FS_NOT_FOUND`；
- `FsFileType`：`file` / `directory` / `symlink` / `other`（`symlink` 只可能来自不跟随链接的 `lstat`）；
- `FsTarget = {targetKey, displayPath}`：`targetKey` 是**后端解析出的不透明身份**（消费方不得解析），`displayPath` 面向模型/界面；
- `FsInfo = {version, type, size?}`：目标不存在时 `stat` 返回 nil；`size` 只对普通文件有值；
- `FsDirEntry = {name, type, target, size?}`：目录的直接子项，只含元数据与已解析目标，**不读内容**；
- **版本令牌**（新鲜度）：由「修改时刻 + 变更时刻 + 大小」派生（实现自定格式，跨实现不保证相同，只要求同实现内稳定可比）；
- 写入意图（`expected` 省略 = 无条件创建/覆盖）：`FsCreateIfAbsent`（已存在则 `notObserved`）/ `FsReplaceIfVersion(version)`（缺失或版本不符则 `staleVersion`）；
- `FsWriteOutcome = {operation(create|update), version, before?, after}`：`before` 是写入前完整内容（新建或后端放弃提供时为空）；
- `FsEditRequest = {oldString, newString, replaceAll}`；`FsEditOutcome = {version, before, after}`。

## 2. FileSystem 端口（服务键 `fs`）

- `resolve(path, cwd?)`：把路径解析为稳定 `FsTarget`——**同一文件（含别名 / 符号链接）必须产出同一 `targetKey`**；`path` 去空白后为空抛 `notFound`；相对路径以 `cwd ?? 实例基准` 解析；
- `processPath(target)`：本执行世界中子进程可打开的规范绝对路径；
- `fileUrl(target)`：规范 `file:` URI；
- `contains(parent, child)`：`child` 是否就是 `parent` 或其子孙（按规范身份，**不解析不透明键**；相等也算包含）；
- `stat(target)`：元数据或 nil；
- `lstat(path, cwd?)`：路径元数据，**不跟随最后一段符号链接**（可为 `symlink`）；
- `readText(target)`：读整文件为 UTF-8 文本——不存在 `notFound`、非普通文件 `notRegularFile`、非法 UTF-8 `notText`；
- `listDir(target)`：按**名字稳定排序**返回直接子项（不跟随链接）；不存在 `notFound`、非目录 `notDirectory`；
- `writeText(target, content, expected?)`：原子创建或替换（见 §3.3）；
- `editText(target, edit, expectedVersion?)`：原子字面替换（见 §3.4）；
- `remove(target)`：删除文件或目录（目录递归）；**目标不存在时静默返回**。

## 3. 本地实现语义

### 3.1 路径规范化（`_normalize`）

- 按 `/` 与 `\` 切段（两平台都吃）；跳过空段与 `.`；`..` 在有可回退段时回退，否则保留；
- 绝对路径（`/` 开头或 Windows 盘符）保留前导分隔符；结果用平台分隔符连接。

### 3.2 目标身份（`_identity`）

- 目标存在 → 取**真实路径**（解析符号链接），因此别名 / 符号链接 / 点段共享同一键；
- 目标不存在但**父目录存在** → 取「父目录的真实路径 + basename」，与展示路径同形（根目录已是真实路径时）；
- 目标与**父目录都不存在** → 兜底返回展示路径；
- 边界（实测行为，已登记为偏离）：父目录在解析**之后**才被创建时，键会从「展示路径」变成「真实父路径 + basename」——即「键在目录创建前后稳定」只在**父目录解析时已存在**的前提下成立，跨后端不得假设。

### 3.3 写入（原子 + 守卫）

1. 目标存在且非普通文件 → `notRegularFile`；
2. 守卫检查：`FsReplaceIfVersion` → 目标缺失或版本不符则 `staleVersion`；`FsCreateIfAbsent` → 目标已存在则 `notObserved`；
3. 记录写入前完整内容（新建为 nil）；
4. **原子发布**：父目录递归创建 → 写临时文件（`<path>.tmp-<微秒>`，flush）→ rename 就位；rename 失败则退化为直接写并清理临时文件；
5. 产出 `{operation, 新版本, before, after}`。

### 3.4 编辑（字面替换 + 歧义守卫）

1. 目标缺失 → `staleVersion`（措辞按「文件已变」）；非普通文件 → `notRegularFile`；
2. `expectedVersion` 非空且与当前版本不符 → `staleVersion`；
3. `oldString` **匹配数为 0** → `editNotFound`；`replaceAll` 假且**匹配数 > 1** → `ambiguousEdit`（消息带匹配数）；
4. 替换后走 §3.4 的原子发布路径，产出 `{version, before, after}`。

### 3.5 本地实现的其余约定

- `processPath` 返回 `targetKey`（本地后端两者同值）；`fileUrl` 由 `processPath` 派生 `file:` URI；
- `contains` 按规范化后的字符串前缀判定（`parent` 等于 `child` 也算）；
- 读取非文本文件按「先整文件 stat → 非 file 抛 `notRegularFile` → 读字节 → 严格 UTF-8 解码」顺序。

## 4. Shell 词汇

- 错误：无异常类型——`run` 只对**基础设施故障** reject；非零退出 / 超时中断 / 取消中断都**正常返回**结果值（这是能力缝的硬约定，模型据此区分「命令跑失败」与「执行器坏了」）；
- `ShellExecRequest = {command, workdir?, timeoutMs?, stdoutMaxBytes?, stdin?, env?, cancelSignal?}`；`ShellExecSpec` 是**补齐并封顶后**的规格（`command` / `workdir` / `timeoutMs` / `stdoutMaxBytes` / `stdin?` / `env?` / `cancelSignal?`）；
- `resolve(request)`：缺省补齐 + **封顶**——`timeoutMs ?? 实例默认` 后按 `maxTimeoutMs` 封顶；`stdoutMaxBytes ?? 实例默认`；`workdir ?? 实例 cwd ?? 进程当前目录`；
- `CollectedOutput = {text, truncated?, spillPath?}`；`ShellRunResult = {exitCode?, timedOut, timeoutMs, stdout, stderr}`——**`timedOut` 与 `exitCode` 互不覆盖**（命令自己处理信号时可能既超时又退出 0）；被信号杀死时 `exitCode` **非 0**（其符号表示随运行时而异，见 §7 偏离）；
- `ShellProcessStatus`：`running` / `completed` / `killed`（恰好落定一次）；`ShellProcessRead = {delta, lossy?, stdoutSpillPath?, stderrSpillPath?}`；
- `ShellProcess`：`status` / `exitCode?`（被信号杀死时非 0）/ `done`（落定后完成，**永不 reject**）/ `readOutput()`（**消费式增量**，不重复投递）/ `kill()`（已结束返回 false，幂等）。

## 5. Shell 本地实现语义

### 5.1 执行方式与环境

- 非 Windows 用 `bash -c <command>`（Windows `cmd /c`，**本移植不做**）；
- 环境变量注入（面向模型的终端环境，关闭颜色/分页器/交互）：`NO_COLOR=1`、`TERM=dumb`、`PAGER=cat`、`GIT_PAGER=cat`，调用方 `env` 覆盖同名项；
- `stdin` 为空时**直接关闭**输入管道（非空则写完即关）；
- **不可逆声明**：命令一旦执行，其对外部世界的效果（写文件、发请求、删数据）无法被任何撤销函数回滚；执行器只返回句柄，不假装存在还原副作用的逆——调用前的审批/守卫是唯一防线。

### 5.2 前台执行（`run`）

1. 起进程 → 写/关 stdin；
2. `cancelSignal` 落定 → SIGKILL（fire-and-forget，不等）；
3. stdout / stderr 各自**有界采集**（超上限截断并置 `truncated`；采集缓冲随时可快照）；
4. 到 `timeoutMs` → 置 `timedOut` 并 SIGKILL；
5. 等进程退出码；**等管道落定最多 250ms 宽限期**（进程被杀后孙进程可能以孤儿身份持有管道写端，宽限期过后按已采集快照返回，不挂到孤儿退出）；
6. 返回 `{exitCode, timedOut, 生效的 timeoutMs, stdout, stderr}`。

### 5.3 后台进程（`start` + 句柄）

- 立即返回句柄，**无超时**；
- 缓冲 stdout/stderr（各受 `maxOutputBytes` 上限），`readOutput()` 返回自上次读取以来的增量，stderr 以 `[stderr]\n…` 段拼接（stdout 空时只给 stderr 段；`lossy` 表示因截断丢了字节）；
- `done` 在**进程退出码与两路输出流都落定**时完成；
- `kill()` 仅在 `running` 时 SIGKILL 并置 `killed`，否则返回 false。

## 6. 装配

- `provideFileSystem(ctx, fs)`：以 `fs` 服务键提供（`provideFileSystemLocal` 用本地后端为缺省）；
- `provideShell(ctx, executor)`：以 `shell` 服务键提供（`provideShellLocal` 用本地后端为缺省）；两者的**生命周期由调用方管理**，服务本身不 close。

## 7. 有意偏离

- **Windows 分支不移植**（AGENTS 已定）：路径规范化的 `\` 切分与盘符判定仍按协议保留（跨平台输入同形），但实际执行与 `cmd /c` 不实现；`/dev/null` 等平台路径不入规格。
- **本地 shell 后端只在 macOS 存在**：iOS 无子进程（`Process` 在 iOS SDK 不可用），故 `LocalShellExecutor` / `LocalShellProcess` 整体置于 `#if os(macOS)`；**`ShellExecutor` / `ShellProcess` 端口与全部词汇跨平台可用**，iOS 由调用方注入自己的执行器（`provideShellLocal` 在 iOS 上缺省执行器会抛 `ShellPortError.localBackendUnavailable`）。
- **JSON 后端缺省目录分平台**：macOS 走 `<swiftus home>/database`；iOS 无 home 目录概念（`homeDirectoryForCurrentUser` 不可用），改落沙盒内 Application Support/database。fs / database / logger / timer / loader / time-context 六域**无平台限制**，iOS 与 macOS 同码。
- **被信号杀死时的退出码**：Dart 的文档注释写「为 null」而实现给的是**负数**（`-9` = SIGKILL）；Foundation 的 `Process.terminationStatus` 给的是**信号号**（SIGKILL → `9`，配 `terminationReason == .uncaughtSignal`）。符号是运行时细节，协议只锁定「非 0」，fixtures 只断言非 0。硬杀统一用 SIGKILL（与 Dart 的 `Process.kill(ProcessSignal.sigkill)` 同款；`Process.terminate()` 发的是 SIGTERM，给被测进程留了自行退出的机会）。
- **shell 输出不做 spill 落盘**：`spillPath` 是「截断且能提供」的可选字段，本地实现**不提供**（结构保留、恒为空）——落盘策略留给上层策略插件。
- **超时的执行器内中断**：Dart 用 `Timer` + `SIGKILL`；Swiftus 用注入的等待器 + `kill(SIGKILL)`，语义等价但可测（AGENTS 的 Clock 纪律）。
- **缺失目标的身份键在「父目录后创建」时会变**：Dart 与本移植一致（父目录解析时不存在 → 兜底展示路径；事后创建 → 变为真实父路径 + basename）。Dart 注释里「目录创建后键仍稳定」的说法只在父目录已存在时成立，按实际行为实现并在此登记。
- **fs 的「无限流」与权限/沙箱码**：`tooLarge` / `permissionDenied` / `sandboxDenied` / `ioError` / `aborted` 是**协议预留**（供沙箱/远端后端使用），本地后端不主动产出（本地 OS 错误按所在环节归到 `notFound` / `notRegularFile` / `ioError` 语义之外的自然失败面，见实现注记）。

## Swiftus 实现注记

- `FileSystem` / `ShellExecutor` 为 `@ContextTreeActor` 协议；本地后端为 `final class`，文件 IO 与子进程**不经 actor 串行**（IO 量大，串行会拖垮整棵上下文树）——按「IO 内部加锁、只在边界上碰 actor 状态」的写法落；
- 版本令牌格式由实现自定（本地后端用「修改时刻微秒 + 变更时刻微秒 + 大小」）；**fixtures 不比对具体版本串**，只断言「同文件两次 resolve 键相同」「换内容后版本变化」「陈旧版本被拒」三条语义；
- 路径规范化复刻 §3.1（`..` 回退、空段跳过、绝对路径保留前导分隔符），用纯字符串运算，不引 Foundation 的 `URL.standardized`（后者对不存在路径与符号链接的处理与协议不同）；
- 原子写沿用「临时文件 + rename」，临时名带微秒后缀；rename 失败退化为直接写（Dart 同款兜底）；
- 严格 UTF-8 解码用 `String(data:encoding:.utf8)`（失败即 nil → `notText`）；shell 输出用**宽松解码**（`allowMalformed` 等价）以免半截字节让整段输出消失；
- shell 的超时与取消经 `ShellWaiter` 缝注入（生产 `Task.sleep`，测试受控），与 S12 `RefreshClock` 同款纪律；
- 后台进程句柄是 `final class`（缓冲 + 游标 + 一次性落定的状态机），`wait()` 语义对应 Dart 的 `done`，`readOutput()` 消费式增量；
- **iOS 可编译（2026-09-29 实测）**：`xcodebuild -destination 'generic/platform=iOS'` 逐 target 验证 9 个 target 全部 BUILD SUCCEEDED；改动仅上述两处平台分支，macOS 侧测试与 Demo 行为不变（281 例双绿）；
- **S17 §7 的 shell 端口偏离在此收口**：`TrackingTaskShellExecutor` 改为包裹本规格的 `ShellExecutor`，任务域内的替身端口（`TaskShellExecutor` / `TaskShellSpec` / `TaskShellRunResult` / `TaskShellProcess`）删除，fixture 与单元测试同步改用本地后端。
