# S16 · Agent Loop 产品化

版本：v1.2 · 日期：2026-09-28 · 来源：conatus_agent；v1.1 增补来源：`telemetry.dart` / `caching.dart` / `context_metrics.dart` / `content_classifier.dart` / `layered_compaction.dart` / `eval*.dart` / `agent_provider.dart`；v1.2 增补来源：`approval*.dart` / `sub_agent.dart` / `snapshot.dart` / `recovery.dart` 与 conatus_foundation `ask_user.dart`
语言中立规格。Swiftus 实现注记见文末。
前置：S3/S4（Session 与派生事件）、S5（工具管线）、S7（压缩）、S10（LLM）。
范围说明：v1.0 覆盖 plan / reflection / router 三件套与 AgentLoop 集成点；telemetry / eval / approval / skill 沉淀 / goal 续行 / autonomous / caching / layered compaction 随对应刀滚动增补。

## 1. 计划（plan）

### 1.1 词汇与事件协议

- `plan/updated` 事件：计划持久化到会话（append-only，取最后一条为当前计划）；载荷 `{goal, steps: [{id, text, done}]}`；
- `PlanStep`：`{id, text, done}`；id 由工具按顺序生成（`s1`…`sn`）；
- `readPlan`：倒序扫会话事件，取最后一条 `plan/updated` 的载荷；没有则 nil；
- `writePlan`：追加一条 `plan/updated`；
- `planSection(session)`：无会话或无计划返回空串，否则 `[当前计划]\n<summary>`；
- `Plan.summary()`：`目标：<goal>` 起，逐行 `\n<N>. [x| ] <text>`（done 为 `x`，否则空格）。

### 1.2 `plan_write` 工具（PlanTool，风险 low）

- 参数：`goal` 必填字符串；`steps` 字符串数组（可选）；
- 执行：steps 逐条 `trim` 后**跳过空文本**，id 按剩余顺序 `s1`…`sn` 生成；写入会话；成功结果 content 为 `plan.summary()`，规范值为计划 JSON；
- `providePlanTool(ctx, session, tools?)`：注册进工具表，随上下文释放撤销。

### 1.3 规划轮（runPlanningPhase）

Agent Loop 里替模型跑一次「只允许 plan_write」的规划轮：

1. 工具表里没有 `plan_write` → 返回 false（未跑）；
2. 组装规划消息：system 为 `<当前 systemText>\n\n先制定一个简洁的执行计划：只调用 plan_write 工具，不要直接回答用户。`，后接原消息序列**跳过第一条**（原 system）；
3. 调模型（**只下发 plan_write 的 schema**）；
4. 对响应里的工具调用逐条：名字不是 `plan_write` 跳过；是则经工具表执行（参数 JSON 解析失败按空表交参数校验）；
5. 刷新消息序列第一条 system 为最新 `systemText()`（计划已进会话，摘要段即时反映）；
6. 返回 true。

### 1.4 Agent Loop 集成（planning）

- `planning: true` 且会话非空且当前无计划 → 正式循环前跑一次规划轮；
- 循环内 `_needsReplan` 置位（反思 replan 置位）且 planning 且会话非空 → 下一步开头清位并重跑规划轮。

## 2. 反思（reflection）

### 2.1 策略（ReflectionStrategy）

`always`（每次工具调用后）/ `onError`（只在工具失败时，**默认**）/ `onRisk`（只在非只读工具后，`riskLevel != low`）/ `never`（关闭）。`parseReflectionStrategy`：大小写不敏感、去空白按名字解析，无法识别返回 nil。

### 2.2 决策解析（ReflectionDecision.parse）

- 优先正则 `"decision"\s*:\s*"?(continue|retry|replan)"?`（大小写不敏感）取 `decision` 值；
- 否则按关键词：含 `retry` → retry；含 `replan` → replan（retry 优先于 replan）；
- 兜底 `continue`。匹配输入先转小写。

### 2.3 Reflector 与 reflectAndRetry

- `Reflector(llm, strategy = onError, options?, maxRetries = 1)`；反思是独立 LLM 调用（options 可传更省参数）；
- 反思 prompt 模板（逐字）：`你是一个任务执行监督者。当前任务：<task>\n当前计划：\n<plan.summary() 或（无）>\n刚执行的工具：<name>\n工具返回结果：<content 截断 800 字符加 …>\n结果状态：<失败|成功>\n\n请评估并按 JSON 回答：{"decision":"continue|retry|replan","reason":"简短理由"}\n- continue：结果符合预期，继续；\n- retry：结果不符合预期，应重试该工具；\n- replan：需要调整计划，重新规划。`；
- `reflectAndRetry`：工具未注册直接返回初值；否则循环 `while shouldReflect && retries < maxRetries`：retry → 重跑该工具（retries+1）；replan → 调 `onReplan` 后停；continue → 停；返回最终采用的结果；
- Agent Loop 集成：工具执行后、回填前应用；`onReplan` 置位 `_needsReplan`；
- `provideReflection`：服务键 `reflection`；策略取参数 → 上下文 `reflectionStrategy`（任意类型，经 parse）→ `onError`；llm 缺省取上下文 `llm`。

## 3. 路由（router）

调模型前的确定性快路径（服务键 `router`）。`Router.route(input) async -> RouteDecision` 三态：

- `RouteReply(text)`：本地直答——直接收口，**不调模型**（写会话事件与收口流程同正常路径）；
- `RouteTools(calls)`：命中确定性工具——作为一条 assistant（toolCalls）+ 若干 tool/result 写入历史后**仍由模型收口**（口径与模型自身下发工具调用一致）；
- `RoutePass`：未命中，落回模型决策（默认行为）。

未装配 Router 时 Agent Loop 行为与无路由完全一致。路由判断与取消信号竞速。

## 4. AgentLoop 集成总览（v1.0 后的完整数据流）

`run(input)`：写 user 事件 → 压缩窗口 → 组装 system（prompt 段 + 历史摘要 + **当前计划段**）+ 历史消息 → planning 规划轮（可选）→ router 快路径（可选）→ 循环（模型 → 工具（→ 反思重试）→ 回填）→ 收口（写 assistant 事件）。

## 5. 观测与缓存（v1.1 增补：telemetry / caching / context-metrics / content-classifier / layered-compaction / eval）

### 5.1 telemetry（服务键 `telemetry`）

- `TelemetryEvent`：`{name, data, time}`；toJson 为 `{name, time: ISO8601, ...data 展开}`；
- `Telemetry` 端口：`emit(event)` + `events` 广播流（每订阅者各得一条流）；
- `InMemoryTelemetry(limit = 1000)`：保留最近 limit 条（超出从头部截断），emit 同步广播；limit 为负快速失败；close 幂等关闭广播；
- `ConsoleTelemetry`：`[name] {json}` 一行一条，events 为空流；writer 可注入；
- `instrumentTools(ctx)`：工具中间件——每次调用发 `tool.called`（tool/isError/ms/args）；失败时**额外**发 `tool.failed`（tool/ms/error）；返回错误结果与执行体抛异常都算失败，两条路径各自只发一次；ms 为墙钟毫秒；
- `TelemetryLlmProvider`：chat 成功发 `llm.request`（provider/model/ms/messages/tools/toolCalls 计数），失败发 `llm.failed`（provider/ms/error）并重抛；chatStream 原样透传；
- `provideTelemetry`：缺省 InMemoryTelemetry，随上下文释放 close。

### 5.2 caching（服务键 `contextCache`）

服务端按请求前缀自动缓存；本插件只度量、不改请求体：

- `CachePlan.of(messages)`：从头的**连续**可缓存前缀——遇第一条 `cacheable == false` 即停（后续可缓存消息也不计入）；指纹以前缀的 JSON 序列做 FNV-1a（64 位，初值 `0xcbf29ce484222325`，质数 `0x100000001b3`，十六进制字符串）；`cacheableChars` 只累计正文 content 字符数；指纹值是实现细节（**不作跨语言比对**，只保证同内容同值、前缀变则变）；
- `ContextCache.recordHit(plan, usage)`：命中判定按序取 `prompt_cache_hit_tokens` / `cache_hit_tokens` / `prompt_tokens_details.cached_tokens`，任一为正数即命中；都取不到按未命中（保守口径）；产出 `context.cache` 遥测（cacheKey/cacheableMessages/cacheableChars/hit）；
- `CachingLlmProvider`：chat 前 planFor、后用 recordHit；**不往请求体加任何字段**；chatStream 透传；
- `provideContextCache`：telemetry 缺省取上下文。

### 5.3 context-metrics

`estimateTokens(text)`：字符数 ÷ 4 向上取整，空串为 0；`estimateMessagesTokens`：逐条累加 role + content + 工具调用（id/name/arguments）。只用于相对度量，不用于计费或硬预算。

### 5.4 content-classifier（服务键 `contentClassifier`）

- `MessageCategory` 八类：systemPrompt / toolDefinition / skillList / toolResult / userPreference / userTask / earlyConversation / recentConversation；
- `CompressionStrategy` 四态：none / keep / summarize / evict。类别 → 策略映射：前三类 none、toolResult evict、userPreference / userTask keep、earlyConversation summarize、recentConversation keep；
- `ContentClassifier` 能力缝：classify 只看单条消息字段（**不看位置**——早期/近期由调用方按 `recentWindow`（缺省 20 条）遍历时决定；分类器不持有索引状态）；
- 规则分类器判定顺序：role tool → toolResult；role system → 含「技能|skill」为 skillList、含「工具|tool」为 toolDefinition、否则 systemPrompt（大小写不敏感）；带 toolCalls 的 assistant → recentConversation；其余命中偏好关键词（`记住|以后都|今后|我喜欢|我不喜欢|不要|务必|始终|偏好`）→ userPreference，否则 recentConversation。

### 5.5 layered-compaction（与 provideCompaction 二选一，同名服务键）

`LayeredCompactor extends Compactor`，只覆盖 summarizeFolded：

- 折叠前先取「会被 deriveAgentMessages 还原」的事件子集（保证事件-消息下标一一对应），逐条按 §5.4 分类；recentConversation 且距末尾超出 recentWindow → 升格 earlyConversation；
- 分桶：evict（工具结果）→ 压成一行说明 `工具 <name>：<首行截 80>（原结果 N 字符，完整内容见会话日志中的 tool/result 事件）`（正文丢弃，**不**额外落盘）；userPreference → 原文保留；summarize → 交给注入的汇总器；其余（keep/none）→ 保留原文；
- 渲染：`[历史摘要]` / `[用户偏好]` / `[工具结果]` / `[保留原文]` 四段顺序排列，空段不占位，段内逐行 `- <trimmed 行>`、段尾空行，整体 trim；
- 埋点 `context.compacted`（tokensBefore/tokensAfter/compacted/kept/toolResults/preferences）；
- `provideLayeredCompaction`：compaction 已是 LayeredCompactor 则直接用；否则以 compaction?.keepRecent ?? 20 构造。

### 5.6 eval

- `EvalCase`：`{id, input, expectedTools?, expectedOutput?, maxRounds?}`（JSON 宽容解析：缺失按空/nil，非字符串插值化）；
- `EvalResult`：`{caseId, passed, actualTools, actualOutput, rounds, durationMs}`；
- `EvalReport`：passedCount / passRate / averageRounds（空报告均为 0）；`compareTo` 基线得 `EvalDiff`（展示 `通过率 +x.x%，平均步数 +y.y`）；
- `defaultEvalJudge`：期望工具为实际子集 ∧ 输出含关键词 ∧ 步数不超限；
- `Evaluator(run, judge)`：逐 case 串行跑（计墙钟耗时）→ judge 判分 → 汇总；judge 在跑完后以实测结果计算。

### 5.7 composeLlm（装饰链顺序）

`provideAgentLoop` 按上下文已提供的能力叠加装饰器，**由外到内**：Session Log（SessionLogLlmProvider，记录请求/响应）→ 缓存度量（CachingLlmProvider）→ 遥测（TelemetryLlmProvider）→ 原始提供方。未提供的能力不包装。telemetry 存在时 AgentLoop 的 onEvent 观察口接到 `telemetry.emit`（`agent.round` / `agent.finished` 入遥测）。

## 6. 执行安全组（v1.2 增补：approval / sub-agent / recovery / ask-user）

### 6.1 ask-user（SwiftusFoundation ask_user 域，随本刀提前）

- `AskUser` 端口：`ask(prompt) async -> String`（等待期间被 cancel 应抛 `AskCancelledException`）+ `cancel()`（幂等，取消全部在途提问）；
- `CliAskUser`：ask 不直接读 stdin——把 prompt 写出并登记在途提问，由 `submit(line)` 投递给最早等待者（测试或自定义输入源驱动）；cancel 后 ask 立即抛；
- `provideAskUser`：服务键 `askUser`，随上下文释放 cancel。

### 6.2 approval（服务键 `approval`）

- `ApprovalRequest`：`{id, toolName, arguments, description, pathArgs, createdAt}`；toolName 为 `plan` 表示整份计划；
- `Approval` 端口：`request(req) async -> bool` + `pending` 广播流 + `preapproved(req) async -> bool`（缺省 false——每次都问；实现方可用「工具 + 路径」粒度表达信任）+ `requestPlan(plan)`（缺省走 request，toolName `plan`，arguments 为计划 JSON，description 为计划摘要）+ `close()`；
- `AutoApproval(approved)` / `RuleBasedApproval(allow)` / `AskUserApproval(askUser, yesWords 缺省 {y yes 是 允许 可以 好}, timeout 缺省 5 分钟)`——提问文案 `是否允许执行 "<tool>"？（<description>） (y/N)`，回答 trim + 小写后命中 yesWords；超时或异常视为拒绝；
- `instrumentApproval(ctx, threshold = high, timeout = 5min)`：工具中间件——工具未注册直通；取出 `Tool.pathParams` 声明的参数取值（非空字符串，支持 `a.b` 嵌套）；`gated = 风险 ≥ threshold ∨ 声明了路径参数`（声明路径参数的低风险工具同样要问——「读文件也按目录授权」）；未 gated 直通；pathArgs 非空且 preapproved → 直通；否则发 `approval.requested` 遥测 → `request`（超时视为拒绝）→ 发 `approval.decided` → 拒绝返回 `APPROVAL_DENIED`（content `用户拒绝执行 "<tool>"`）；
- `provideApproval(instrument = true)`：缺省 `AutoApproval(false)`（安全优先）；instrument 为 false 只提供服务不挂拦截（拦截阈值由别处决定，避免两层中间件重复询问）；随上下文释放 close。

### 6.3 sub-agent（spawn_agent 工具，风险 medium）

- `kDefaultSubAgentPrompt`：`你是内部子助手，只完成交办的一件事。只依据工具返回的事实作答，禁止编造；完成后直接给出结论简报（尽量简短），不要寒暄、不要反问用户。`；
- `SubAgentResult`：`{status: success|failed, output, rounds, tool_calls}`；
- `SpawnAgentTool(host, llm, tools, defaultTools?, maxRounds = 8, subAgentPrompt, systemPrompt?)`：`call(task, tools?, max_rounds?)` → `run(task, allowed, maxRounds)`：
  - 子上下文在宿主下派生（`host.plugin`，随宿主释放），子会话 id `subagent-<seq>-<微秒>`，子注册表只含白名单工具实例；
  - 白名单：显式 `tools` 参数（只留注册表里存在且非 spawn_agent 的名）→ `defaultTools`（同过滤）→ 主注册表全部非 high 且非本工具；
  - 子 AgentLoop（systemPrompt 缺省不用、defaultSystemPrompt 用 subAgentPrompt、maxSteps = maxRounds）跑任务；失败收敛为 `status: failed`（`子 Agent 失败：<error>`），不向外抛；finally 释放子上下文；
- `provideSpawnAgent`：注册工具。

### 6.4 recovery（服务键 `recovery`）

- `SessionSnapshot`：`{version: 1, sessionId, savedAt?, events[]}`；fromJson 版本不符抛 `RecoveryException('unsupported-version')`；
- `SnapshotStore` 端口：save（覆盖）/ load（不存在 nil）/ list / delete；`MemorySnapshotStore` 进程内实现；
- `RecoveryService`：`snapshot(session)`（建议每轮结束或会话释放调用）/ `load(id)`（不存在或版本不符抛 `RecoveryException('not-found' | 'unsupported-version')`）/ `restore(id)`（由快照重建带事件种子的会话，可直接交给 Agent Loop 继续对话）/ list / delete；
- `provideRecovery`：存储优先级 store > 'database' 服务（DatabaseSnapshotStore，W3 后补）> 内存实现。

### 6.5 skill 沉淀（v1.3 增补；记忆前置见 S13）

- `SkillStep`：`{toolName, arguments}`（字符串值里的 `{{name}}` 会被技能入参替换）；
- `SkillTool(name, description, steps, tools, params?)`（风险 medium）：按序执行各步（参数先经 `resolveSkillArg` 用 `{{name}}` 占位符替换）；任一步失败返回 `技能 "<name>" 在步骤 <tool> 失败：<content>`（error 透传）；成功 content 为**最后一步**的结果、规范值为全部输出列表；`deriveSkillParams` 从占位符派生必填字符串参数（去重，正则 `\{\{(\w+)\}\}`）；`toJson`/`fromJson` 持久化；
- `skill_namer`：`skillNameFrom(text)`（转小写、非 `[a-z0-9]` 替换为 `_`、剥首尾 `_`，空则 `skill`）；`deterministicSkillNamer`（名 `skill_<工具序列下划线连接>`、描述 `自动沉淀的技能：依次调用 <顿号连接>。`）；`llmSkillNamer(llm, options?)`（提示词只回 JSON，解析失败回退确定性）；`parseSkillMeta`（正则 `"name"\s*:\s*"([^"]+)"` / `"description"\s*:\s*"([^"]*)"` 大小写不敏感，name 缺失回退）；
- `SkillLibrary(threshold = 3, namer?, approval?, memory?)`（threshold < 1 快速失败）：
  - `record(task, steps)`（空步骤忽略）/ `recordTools(task, tools)`；
  - `maybeExtract(tools, namer?)`：取首条达到阈值的**未提取过**的签名轨迹（签名 = 工具名 `>` 连接）；标记已提取；`_isSafe`（任一步工具未注册或 risk == high 则不沉淀）；命名（显式 > 库 > 确定性）→ 构造 SkillTool → 有 approval 先 `request`（toolName `skill:<name>`，id `skill-<微秒>`）不批则返回 null → 未注册则注册 → 入库 → `_persist`（memory 非空时 `remember(jsonEncode(skill.toJson()), tags: {skill})`）→ 返回技能；
  - `restore(tools, memory?)`：从记忆库带 `skill` 标签的条目反序列化注册（损坏条目跳过；空名或已注册跳过）；返回恢复数；
  - `skills` / `traceCount`；
- `toolNamesFromEvents(events)`：从 `tool/result` 事件提取工具名序列（data 非对象给空串）；
- `provideSkillLibrary(ctx, library?, llm?, tools?, memory?, approval?, threshold = 3, namer?)`：服务键 `skill`；命名器优先显式 → llm（或上下文 llm）装配 llmSkillNamer → 确定性；审批/记忆缺省取上下文。

### 6.6 AgentLoop 记忆接入（v1.3 增补）

- `AgentLoop` 增 `memory` 参数：buildSystemText 的记忆段（`[相关记忆]` 段，逐行 `- <text>`，最多 `memoryLimit` 条，空记忆不占位）；`_finish` 时 `remember('用户：<input>\n助手：<reply>', tags: {conversation})`（reply 非空才记）；`run` 开头 `memory.load()`；
- `memoryLimit` 缺省 5。

## 7. Goal（v1.4 增补）

### 7.1 词汇与事件协议

- `goal/changed` 事件：目标状态**整值替换**持久化到会话（append-only，折叠最后一条）；派生状态只折叠 `ownEvents`（fork 不继承目标）；
- `GoalRevision`：`{text, revisedAt}`（修订历史含初版）；`Goal`：`{id, text, status, round, maxRounds, createdAt, updatedAt, revisions, blockReason?}`；id 形如 `goal-<微秒>`；status ∈ active / paused / blocked / completed / cleared；`isTerminal`（completed / cleared）/ `isAdvanceable`（active）；
- `restoreGoalState(session)`：倒序扫 ownEvents 取最后一条 `goal/changed`；无事件或最后状态为 `cleared` → nil；
- 每会话至多一个当前目标。

### 7.2 GoalService（服务键 `goal`）与状态机

`current`（无目标或 cleared 时 nil）/ `create(text, maxRounds?)`（已有非终态目标抛 `already_exists`）/ `edit(text)`（仅 active / paused 可编辑）/ `pause()`（仅 active）/ `resume()`（paused / blocked → active，清 blockReason）/ `complete()`（终态，走 approval 确认）/ `block(reason)`（active / paused 可阻塞）/ `clear()`（任意状态 → cleared 终态，走 approval 确认）/ `advanceRound()`（active 才推进；`round + 1 >= maxRounds` 时自动 block（`kGoalRoundLimitReason`）并置 round = maxRounds）/ `changes` 流 / `restore(session)` / `dispose()`。

错误码：`already_exists` / `invalid_status` / `no_goal` / `cancelled`（approval 拒绝，消息「用户取消」）。

### 7.3 默认实现（DefaultGoalService）与能力缝（GoalSeams）

- `GoalSeams` 集中解析 session / systemPrompt / approval / telemetry 四个可选依赖（显式 > 上下文 > 降级：不持久化 / 无注入 / 自动批准 / 无埋点），承载使用点：`appendEvent`（整值替换写事件）、`emit`（`goal.created` / `goal.edited` / `goal.paused` / `goal.resumed` / `goal.blocked` / `goal.completed` / `goal.cleared` / `goal.advanced`，data `{id, status}`）、`confirm`（approval request，拒绝抛 `cancelled`）、`syncSection` / `detachSection`（`goal` 段：有目标注入 order 50 的 PromptSection、无目标撤销；段文本 `[当前目标]\n<text>` + 进度 `\n进度：第 N / M 轮`（round > 0 时））；
- `DefaultGoalService`：构造时若 session 可解析则 restore；每次变更 `_commit`（存值 → 写事件 → 同步段 → changes 广播 → 埋点）。

### 7.4 续行驱动器（GoalRoundDriver）

- `kGoalContinuationPrompt` = `[系统] 继续推进当前目标。`；
- `shouldContinue()`：无目标 → wait；completed / cleared / blocked → stop；paused → wait；active 且 `round < maxRounds` → proceed，否则自动 block（轮次上限原因）→ stop；
- `advance(cancel?)`：proceed 才继续——`goal.advanceRound()` → 再查（仍 proceed）→ `agent.run(kGoalContinuationPrompt, cancel)`；返回 nil 表示停止续行；
- AgentLoop 每轮收口后经 `goalDriver` 续行：driver 非空且会话未关闭 → `advance(cancel)` 返回非 nil 则作为本轮结果（递归续行直至等待用户或停止）。

### 7.5 工具与装配

- 四工具（low：create / edit / complete；medium：clear）：`create_goal(text, max_rounds?)` / `edit_goal(text)` / `complete_goal` / `clear_goal`；成功口语化文案（`好的，我会持续关注：<text>` / `好的，目标已更新：<text>` / `目标已标记完成。` / `好的，目标已清除。`）；GoalException → `ToolResult.failure(message, error: ToolError(code, message))`；`pause` / `resume` / `block` 不暴露给模型（用户命令或驱动器调用）；
- `provideGoal(ctx, goal?, session?, prompt?, tools?, approval?, telemetry?, defaultMaxRounds = 256)`：提供服务 + 注册四工具 + `ctx.inject(['agentLoop'])` 后置挂 `GoalRoundDriver` 到 `AgentLoop.goalDriver`（agentLoop 依赖消失或上下文释放自动摘除，onDispose 置 nil）+ 随上下文释放 dispose。

## 8. Autonomous（v1.5 增补：自主运营；priority 引擎随附）

### 8.1 策略（AutonomousPolicy，Capability Seam）

- 硬约束：`dailyBudget`（美元；∞ 无限制）/ `activeWindow`（TimeWindow?，null 全天）/ `allowedActions`（白名单；空集不限制）/ `requireApproval`（黑名单）/ `maxContinuousRounds`（缺省 8）/ `maxTurnDuration`（缺省 5 分钟）/ `requireHumanInLoop`（缺省 false）；
- `firstViolation(steps)`：首个命中黑名单、或白名单非空且未在白名单的工具名；无违规 null；
- `TimeWindow(start, end)`：0-23 点内一天时刻，支持跨午夜（start > end）；end 允许到 48 小时内；`contains(time)` 端点含（跨午夜 `t >= start || t <= end`）；`nextStart(from)`（从 from 之后窗口的下一次开始，取 start 当天或次日）；
- `CostTracker`：`todayCost`（预算输入缝，不提供视为无预算限制）。

### 8.2 PriorityEngine

纯函数：`score = importance * 0.5 + urgency * 0.3 + (1 - progress) * 0.2`；importance / urgency 缺省 5 可按 goal.id 覆盖；progress = round / maxRounds clamp 0-1（maxRounds ≤ 0 时 0）；`selectNext` 取最高分（同分保持原序，单趟扫描严格大于才替换）。

### 8.3 默认实现（DefaultAutonomousRunner + AutonomousLoop + AutonomousSeams）

- `kAutonomousContinuationPrompt` = `[系统] 自主运营：继续推进当前目标。`；
- `AutonomousResult`：`{turns, goalsAdvanced, totalCost, stoppedReason}`；`StopReason`：completed / budgetExceeded / windowEnded / maxRoundsReached / humanRequired / manualStop；
- `AutonomousRunner` 协议：`run()`（同一时刻只允许一次，重复调用抛错）/ `stop()`（中断睡眠等待，run 以 manualStop 收尾）/ `isRunning` / `setPolicy` / `policy`；run 结束后 `_stopped` 复位（runner 可复用）；
- `AutonomousLoop.iterate(turns, advanced)`：一轮完整迭代——`_earlyStop`（约束检查 + 目标状态）→ 取目标 → `_runTurn`（带单轮时长上限，超时经 AgentCancel 真取消：以 AgentCancelled 上抛、不写事件、迟到结果丢弃，超时轮按空轮记录并审计 `autonomous/turn_timeout`）→ 审计/埋点 → `_humanCheck`（策略外工具或 requireHumanInLoop 时经审批确认，拒绝 → humanRequired）→ `_advanceGoal`（终态/阻塞/暂停不再推进）→ 返回（停止原因, 成本增量）；
- 硬停止：会话关闭 → manualStop；`cost > dailyBudget` → budgetExceeded；轮次数 ≥ maxContinuousRounds → maxRoundsReached；窗口外且 nextStart 在今天 → 睡眠等待（被 stop 中断 → manualStop），否则 windowEnded；
- `AutonomousSeams`：集中承载 costTracker / costOfTurn / approval / telemetry / sessionLog 五个可选依赖（缺省降级）；`costDelta`（正增量）/ `turnCost`（costOfTurn 钩子精确折算负值截 0，否则今日增量近似）；`askApproval`（缺省自动批准）；`audit('autonomous/turn', {goalId, priorityScore, replyLength, steps, costDelta})` / `audit('autonomous/finished', ...)` / 埋点 `autonomous.round` / `autonomous.finished`；
- `provideAutonomousRunner(ctx, agent, goal, session, policy?, costTracker?, costOfTurn?, approval?, telemetry?, sessionLog?)`：服务键 `autonomousRunner`；未显式传入的可选依赖从上下文惰性解析。**注意**：传给 agent 的 AgentLoop 不应挂 goalDriver（续行驱动器与 Runner 轮次记账双算），且应绑定与 session 相同的会话。

### 8.4 定时启动（AutonomousSchedule）

- `autonomousDelivery(runner, onError?)`：到期触发——未在运行时后台跑一轮返回 true；已在运行返回 false（不写 dispatch，记录保持活动）；单轮失败经 onError 上报（缺省静默），不中断后续调度；
- `provideAutonomousSchedule(ctx, runner, schedule?, clock?, onError?)`：服务键 `autonomousSchedule`（不占用 `scheduleRuntime` 服务键，可与宿主自己的到期投递并存）；依赖 `schedule` 服务；会话上任何 `schedule/change` 事件落盘触发 `requestDrive`（新建提醒无需宿主介入即可定时触发）；装配时立即推导一次；随上下文释放 dispose。

## 9. Plan Mode（v1.6 增补）

### 9.1 词汇与事件协议

- `plan/mode` 事件：状态持久化到会话（append-only，折叠最后一条）；派生只折叠 `ownEvents`（fork 不继承）；
- `kPlanModePolicy` 段文本（`plan:policy`，order 100）：`You are in plan mode. Use web_search and ask_user to gather information before presenting a complete plan through exit_plan_mode. Do not execute mutating operations until the plan is approved.`（只提 web_search 与 ask_user，不提读本地文件——语音优先场景）；
- `PlanModeState`：inactive / active；`restorePlanModeState`（倒序取最后一条 plan/mode，state == active 判 active）。

### 9.2 PlanMode 服务与默认实现

- `PlanMode`：`state` / `enter()` / `exit()` / `submitPlan(plan) async -> Bool` / `changes` 流 / `dispose()`；
- `DefaultPlanMode` 四缝（session / systemPrompt / approval / telemetry，缺省降级）：构造时若 session 还原为 active 则立即 attachPolicy；`enter`（幂等：attachPolicy → 写 active 事件 → 广播 → `plan.entered`）；`exit`（撤销段 → 写 inactive → 广播 → `plan.exited`）；`submitPlan`（approval 缺省自动批准，走 `requestPlan`，先发 `plan.submitted`）；`dispose`（active 时先 exit）；
- `providePlanMode`：提供服务 + 注册 `exit_plan_mode` 工具 + 挂拦截中间件（激活时拒绝 `riskLevel >= medium`：`PLAN_MODE_BLOCKED`，content `Plan mode is active. Please submit a plan through exit_plan_mode first.`，不限制只读工具）。

### 9.3 exit_plan_mode 工具（low）

- 参数 `goal` 必填 + `steps` 数组；steps 逐条 trim、跳过空、id 用**累计** `s1…sn`；
- `submitPlan` → 批准则 `exit()` 并返回 `Plan approved. Proceeding with execution.`；拒绝保持激活、返回 `Plan rejected. Please revise based on user feedback.`。

## 10. Prompt Evolver（v1.6 增补）

### 10.1 词汇与协议

- `PromptVariant`：`{id, sectionName, text, reason, createdAt, parentId?, score?}`；
- `PromptStore`：内存权威存档，可选 database 持久化（本刀内存档，database 档位 W3 占位）；`load`（损坏记录跳过）/ `save` / `find` / `all`；
- `analyzeFailurePatterns(llm, traces)` / `generateVariant(llm, prompt, sectionName, failurePatterns, parentId?)` / `sectionText(prompt, name)`（未注册抛错）——prompt 模板为协议文本；
- `PromptEvolver`：`propose(sectionName, lowQualityTraces)`（轨迹数 < minTraces 返回 nil）/ `evaluate(variant)` / `promote(variant, threshold = 0.05)` / `rollback(variantId)`（不存在抛错）/ `current` / `history`（创建时间升序）；
- `EvolutionDecision`：promote / reject / insufficient；`EvolutionResult`：`{decision, variant(带评估得分), baselineScore, variantScore, improvement}`。

### 10.2 默认实现（DefaultPromptEvolver）

- `restore()`：从存档恢复历史，最后一条为 current；
- `propose`：轨迹不足返回 nil；LLM 分析失败模式 → 生成变体（parentId = current.id）→ `prompt.proposed` 埋点；
- `evaluate`：预算内用例（`estimateTokens(input)` 累计 ≤ maxBudgetPerRun）A/B——先跑 baseline → 临时 swap 该 section（A/B 评估期间临时替换，**finally 恢复**）→ 跑 variant；improvement = variantRate - baselineRate；decision 按 `_decide`（> 0.05 promote / < -0.02 reject / 否则 insufficient）；
- `promote`：improvement < threshold 返回 false；approval 确认（`promote_prompt`，arguments {section, improvement, variant}，description `提示词改进 +X.X%，确认晋升？\n<200 字符预览>`）；通过后 archive 当前 → swap → store.save → current → `prompt.promoted`；
- `rollback`：find 目标 → archive 当前 → swap → save → current → `prompt.rolled_back`；
- `providePromptEvolver`：服务键 `promptEvolver`；evaluator / sessionLog / prompt 必需（显式传入）；llm 缺省取上下文 `'llm'`（缺失抛错）；evalCases 缺省为空（此时 evaluate 得 insufficient 因为无用例——passRate 0/0）。

## 11. 有意偏离

（无。）

## Swiftus 实现注记

- `Plan` / `PlanStep` 为 Sendable struct，JSON 形状经 `jsonValue` / `init(jsonValue:)` 往返；
- `ReflectionDecision.parse` 的正则用 Swift Regex（大小写不敏感）；
- `Reflector` / 路由 existential 均为 `@ContextTreeActor`；`RouteDecision` 为带关联值 enum；
- AgentLoop.Config 增补 `planning` / `reflector` / `router`；`buildSystemText` 的 `SystemTextInput` 增补计划段（planSection）。
