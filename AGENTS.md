# AGENTS.md

> 面向 AI 编码代理的项目说明。本文件假设读者对项目一无所知。

## 项目概览

**swiftus** 是 [conatus](https://github.com/Fi2zz/conatus)（Dart 实现的「时空可组合性」编程范式框架：可逆效应 + 反应式共效应）的 Swift 移植版，命名延续 cordis（TS）→ conatus（Dart）→ swiftus（Swift）的拉丁谱系。移植动机是摆脱 Dart 运行时单一依赖，使框架成为语言中立的资产。

**当前状态（2026-09-30）**：**移植范围全部收口（W1–W3 完成）**——W1 的 core / credentials 最小集 / llm / prompt / tool / skill 之上，Compaction / Schedule / session 持久化层 / Agent 全特性 / 任务中心全部就位；W3 的凭据全量 + SigV4（S12 v1.1 / S15）、Foundation 全部 14 个能力域（S18 fs+shell、S19 database/timer/time-context/logger/loader）、Cron（S9）、联网搜索与抓取（S20）、MCP 客户端（S11）均已落地。离线 Demo `swift run swiftus-demo` 跑通「提问 → 工具调用 → 回填 → 收口」，并**逐段演示**会话持久化（S4）/ 任务中心（S17）/ 提醒（S8）/ 定时任务交付（S9）/ 联网搜索（S20）/ MCP server 工具（S11）——一条会话贯穿全程，全部离线（脚本化模型 + 进程内 MCP server + 临时目录，无需 Key / 无需网络）。swift-testing 345 例 71 套件 debug+release 双绿、release 零警告。外部依赖：Yams（仅 SwiftusSkill）+ 系统 CryptoKit（SigV4）。平台 floor macOS 13 / iOS 16（§5.6 抬升；iOS 侧已逐 target 实测可编译：**shell 与 MCP 的 stdio 领域整体只在 macOS 存在**，iOS 表面不暴露）。没有 CI。

移植范围（已拍板）：

- **做**：conatus 稳定 14 包中的 12 个——core / foundation / credentials / llm / search / skill / mcp / schedule / cron / compaction / agent / tasks；
- **不做**：`conatus_code`（TUI 编码智能体子模块）、`conatus_asr` / `conatus_tts`（语音能力缝）、8 个实验性包（workflow / ontology / team / intent 等，等 Dart 侧 API 稳定后另立阶段）。

## 四条铁律（不可违反）

1. **规格先行，不逐行翻译 Dart**——每个领域动工前先产出该领域的语言中立规格（见下方「规格体系」），code review 的追问是「这句话在规格哪条」；
2. **语义对齐靠共享 golden fixtures**——不逐条翻译 Dart 侧约 1600 个测试，而是从 Dart 侧导出行为级 fixtures 两端共用；
3. **Swift 惯用法 API**——async/await + actor + Codable，不追求与 Dart 签名 1:1 对应；API 形状允许偏离，语义不偏离；
4. **conatus 只读，错误只在 Swift 侧修正**——发现 Dart 侧 bug 不得在 conatus 仓修复；fixtures 仍按 Dart 实际行为原样导出，Swift 的修正语义登记为对应规格文档中的「有意偏离」条目（Dart 行为 / Swift 修正语义 / 理由三要素齐备）；待上游 conatus 自修后重新导出 fixtures 并移除偏离条目。

## 技术栈与构建

- 语言/工具链：Swift 6（`swift-tools-version: 6.0`，当前实测 Swift 6.3.3），**Swift 6 strict concurrency** 语境下开发；
- 包管理：Swift Package Manager 单仓库多 target，无 `Package.resolved`（尚未引入外部依赖）；
- 平台：`Package.swift` 声明 **macOS 13 / iOS 16** floor（2026-09-27 抬升：并发 API / AsyncBytes / Clock 突破工具链默认值，详见方案书 §5.6）；
- 许可证：MIT。

常用命令：

```bash
swift build                  # debug 构建（当前骨架秒级完成）
swift build -c release       # release 构建
swift test                   # 尚无测试 target；测试落地后用 swift-testing（@Test + 参数化）
```

波次出口门槛（方案书 §四）：fixtures 全绿 + swift-testing 单元覆盖语义关键点 + `swift build -c release` **零警告**。CI（GitHub Actions）由维护者稍后配置；落地前 debug + release 双跑 fixtures 以本地手动执行代替（release 优化下时序会变，必须双跑，见坑 #8）。

## 仓库布局与模块划分

```
Package.swift               # 唯一清单：13 个 library target，无外部依赖
Sources/
  Swiftus/                  # 伞产品：仅 @_exported import 其余 12 个 target
  SwiftusCore/              # 内核：Context / EffectScope / Reactor（可逆效应语义）
  SwiftusFoundation/        # 14 能力域：tools / session / session-log / system-prompt /
                            #   memory / database / fs / shell / time-context / timer /
                            #   logger / loader / ask-user / uuid（14 域已全部落地：S18 / S19）
  SwiftusCredentials/       # 凭据五种来源 + AWS SigV4 签名链
  SwiftusLLM/               # chat / responses 双形态、流式增量、fallback 链
  SwiftusCompaction/        # 压缩切点（平衡切点）算法
  SwiftusSearch/            # 4 个 provider 顺序回退
  SwiftusSkill/             # skill frontmatter 解析与目录发现/注册表
  SwiftusMCP/               # MCP 客户端：stdio / http / sse 传输 + JSON-RPC 2.0
  SwiftusSchedule/          # 调度选择器、IANA 时区 / DST 边界
  SwiftusCron/              # cron 表达式引擎、注册表、历史账本、运行时（3s/15s tick）、五工具、JSON 存储
  SwiftusAgent/             # Agent Loop：plan / sub-agent / reflection / telemetry /
                            #   eval / approval / skill 沉淀 / recovery / autonomous schedule
  SwiftusTasks/             # 任务编排
docs/.handoffs/             # 两份权威文档（中文，移植的全部决策依据）。
                            # 按约定**只留本地、不入库**（.gitignore 已显式记录），
                            # 故工作区里可能是空的；需要时从本机副本读取：
                            #   swiftus-移植方案书-v1.2.md      ← 主方案，自洽可读
                            #   conatus-Swift移植可行性评估报告-v2.3.md ← 工作量与决策依据
                            # 手上没有时，决策依据以本文件 + spec/S*.md 的「有意偏离」条目为准
```

依赖方向（自上而下无环，镜像 conatus 包结构，`Package.swift` 为准）：

| target | 依赖 |
|---|---|
| SwiftusCore | — |
| SwiftusFoundation | Core |
| SwiftusCredentials | Core |
| SwiftusLLM | Core, Credentials |
| SwiftusCompaction | Core, Foundation |
| SwiftusSearch | Core, Credentials, Foundation |
| SwiftusSkill | Core, Foundation |
| SwiftusMCP | Core, Credentials, Foundation |
| SwiftusSchedule | Core, Foundation |
| SwiftusCron | Core, Foundation |
| SwiftusAgent | Core, Foundation, LLM, Compaction, **Schedule**（实测 conatus_agent 依赖 schedule，勿删） |
| SwiftusTasks | Core, Foundation, Agent, Schedule |
| Swiftus（伞） | 全部，仅再导出，不写实现 |

注：SwiftusAgent **不依赖** SwiftusSkill——「skill 沉淀」是写技能文件能力，目录发现/注册表归 SwiftusSkill。

## 执行顺序（W1–W3）

- **W1「能跑起来」**：Core → LLM（含 Credentials 最小集）→ prompt / tool（Foundation 子集）→ Skill → 端到端离线 Demo（脚本化模型，无需 Key）；
- **W2 产品化**：Compaction + Schedule + Agent + Tasks（Agent Loop 全特性）；
- **W3 能力缝（按需触发，不预设顺序）**：Cron + Search + MCP + Credentials 全量（含 SigV4）+ Foundation 其余能力域（fs / shell / database / timer 等 W1 不处理，按需后补）。

**演进同步纪律**：swiftus 版本以 Dart 侧 git tag 为锚（如「对齐 conatus v0.17.0」），不追 master 漂移；Dart 侧语义变更时先改共享 fixtures，两端同步过测才算该变更完成。

## 规格体系（动工前置条件）

规格沉淀为**滚动式**：每个领域动工前，该领域对应规格文档与 fixtures 必须就绪。规格编号滚动（S1 起；S11 留给 MCP，S20 是 W3 中途新增的 Search 域），要点见方案书 §3.1，包括：S1 效应语义（LIFO 撤销/幂等/迟到登记/重入收敛 maxRounds=100/循环依赖检测）、S2 上下文树、S3/S4 Session 事件 JSONL 格式与 fork/replay、S5 工具管线（schema 白名单投影、失败码全集、超时优先级）、S6 Prompt 装配、S7 压缩切点、S8 调度语义（DST 缺口拒绝、重叠取较早）、S9 Cron 语义（含「无时区信息的 `at` 按 UTC 解释」「预分配记录标识前先加载账本」两条有意偏离）、S10 LLM 协议、S11 MCP 客户端、S12 凭据、S13 Memory 召回（中文二元组打分）、S14 Skill catalog、S15 SigV4、S16 Agent Loop 产品化、S17 任务中心、S18 Foundation 能力域（fs / shell）、S19 Foundation 能力域（database / timer / time-context / logger / loader）、S20 联网搜索与抓取。

- 规格文档与 fixtures 均放本仓 `spec/` 目录（规格 `spec/*.md`、用例 `spec/fixtures/s*/`）——**S1–S20 全部就位**（fixtures 覆盖 s4/s7/s8/s9/s11/s12/s13/s15/s16/s17/s18/s19/s20；S11 的传输层不进 fixtures，由 Swift 侧单元测试 + Demo 承担，理由见 `tool/export_fixtures/README.md` 的 S11 段）；
- fixtures 由 Dart 脚本导出器（本仓 `tool/export_fixtures/export_s*.dart`）在本地 conatus checkout 上导出并校验，**fixtures 以 Dart 侧行为为准绳导出，不是手写**；
- 每条规格至少 3 个用例；发现语义漏译时补一条 fixture 而非补丁代码；
- **fixtures 不锁语言运行时序**：事件循环投递时机、广播流订阅时机之类的表面差异不进 fixture，改由 Swift 侧单元测试断言（见 HANDOFF「已采的坑」）。

## 测试策略

- 测试框架用 **swift-testing**（`@Test` + 参数化），不用 XCTest 新写测试；
- 两层测试：① 通用 fixtures 运行器（读 JSON → 驱动实现 → 比对输出），swift-testing 参数化挂载，随第一个数据型规格（S5/S6/S10）落地；② 常规单元测试守语义关键点；
- 时间确定性：所有 timer / schedule / cron / time-context 模块只接受注入的 `Clock`（生产 ContinuousClock，测试 TestClock 固定推进），**禁止任何模块直接读系统时钟**；
- 语义不变式示例：「模型可见即已记录」（S4）、dispose 收集错误不外抛（S1）、release/debug 双跑 fixtures。

## 已定稿的关键设计决策

- **服务查找**：Dart 的 `require<T>('key')` 改为类型化 phantom key（`ServiceKey<Logger>("logger")`），编译期保类型、运行期保字符串兼容；不接受全 `Any` + 强制转换；
- **动态 JSON**：内部事件载荷统一 `JSONValue` 枚举（object/array/string/number/bool/null；number 必须 Int64 / Double 双形态，否则 SigV4 与 seq 边界会炸），落盘边界用 Codable 编解码到 JSONValue；
- **并发**：Context / Reactor / EffectScope 先做「单 actor 承载整棵上下文树」的保守方案，性能不足再切非隔离 + 显式同步；**禁止用 `@unchecked Sendable` 蒙混过关**（并发洞 fixtures 抓不到）；
- **效应撤销 × Task 取消**：`dispose()` 保持同步签名；异步清理登记为「同步触发 + 句柄入桶」；上下文释放时取消该上下文派生的全部 Task；「Task 已取消后又登记」的竞态必须有 fixture；
- **外部依赖最小集**（尚未加入 Package.swift，需要时再引）：Yams（仅 skill frontmatter）、CryptoKit（SigV4 HMAC；若考虑 Linux 用 swift-crypto）；网络层统一 URLSession（含 WebSocketTask / bytes 流），**不引第三方 HTTP 框架**；
- **不移植** Windows 分支（cmd /c）；原子写沿用「临时文件 + rename」。

## 已知坑清单（方案书 §六，动手前必读）

1. Dart zone 错误模型无对应物：效应管线内错误必须收敛为结果值（工具失败码 S5），不外抛；
2. NSRegularExpression ≠ Dart RegExp：正则用 Swift Regex（5.7+）重写并逐条对齐差异（命名组、lookahead）；
3. IANA 时区缩写歧义：规格 S8 要求显式 IANA 名，fixture 含 `Asia/Shanghai`；
4. SSE 解析：URLSession bytes 是字节流，事件边界（`\n\n`）与重连语义需手写解析层，别假设按行到达；
5. JSON 数字精度：Dart `num` 不区分 int/double（见上 JSONValue 双形态）；`JSONSerialization` 不接受顶层标量且抛 ObjC 异常（JSONL 拼字节写、字符串转义自己实现），`JSONValue.jsonData()` 用 `.sortedKeys`（与 Dart 插入序不同，文本比对要两端同序）；
6. 中文二元组打分（S13）：Swift String 按 grapheme cluster 实现，与 Dart UTF-16 语义不同，fixtures 必须有中文用例；Dart 的 `weekday` 是 1=周一、Foundation 是 1=周日，cron 星期换算是**减一**不是 `% 7`；`ISO8601DateFormatter` 要求带偏移，无时区串要自己配 GMT 的 `DateFormatter`；
7. dispose 期间再 provide：actor 模型下消息交错顺序不同，M1 的 actor 方案必须用重入用例逐条验；
8. release 构建差异：时序会变，CI 前以本地 debug + release 双跑 fixtures 代替；测试里等「投递到达」用有界轮询，别用固定 `Task.sleep`（release + 全量并发下会踩空）；
9. **协议扩展里给默认实现的成员，覆写会被静默忽略**：`Tool.schema` 原先只在扩展里定义，`any Tool` 存在值上的成员访问走 witness table、静态派发到扩展那份实现，于是 MCP 适配器「透传服务端 `inputSchema`」的覆写完全不生效（模型看到空 schema）——**fixtures 直接调具体类型测不出来，是 Demo 端到端先发现的**。凡是要被覆写且调用方可能拿存在值的成员，一律声明为协议要求（回归用例 `S11TransportTests.schemaOverrideSurvivesExistential`）；
10. **阻塞调用绝不能留在协作线程池**：`FileHandle.availableData` 与 `Process.waitUntilExit` 写在 `Task` 里会占满线程，让同进程的 `Task.sleep` / URLSession 回调一起饿死（表现为「别的用例莫名挂住」）；两者都放专用 `DispatchQueue`，再用 `Task` 回隔离域；
11. **Dart 里 future 失败时若还没有错误处理器会立刻终止整个导出器**：导出会触发故障的用例必须**先**建好 `_guard` 守护再触发（`_guard` 返回的 future 要先创建、后 await）；
12. **验证导出器自身也要用边界轮询**：`Task { try await … }` 到真正发出之间没有同步点，紧接着的 `close()` / `fail()` 可能跑在它前面，待办表扑空就永久悬挂；用「有界轮询等某个方法真的被发出」而不是固定 sleep。

## 文档与沟通约定

- 项目文档与注释使用**中文**；权威设计文档为 `docs/.handoffs/` 下两份（方案书为主，评估报告为决策依据），改动涉及其中已拍板的决策时须同步更新文档并写变更摘要；
- 单人项目连续性纪律：仓库根维护 HANDOFF.md（现状 / 已完成 / 下一步 / 验证命令），小步提交（当前尚未创建，首次交接时补上）；
- 提交信息风格参照现有历史：中文、可带 conventional 前缀（如 `build: SwiftPM 仓库骨架，13 个 library target 镜像 conatus 包结构`）；
- 提交纪律：每次改动完成后即提交；配置了远端即推送，推送最多等待 15 秒，失败或超时记录原因后不阻塞、不再重试，直接继续下一任务（2026-09-27 拍板）。
