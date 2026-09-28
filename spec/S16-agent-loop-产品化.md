# S16 · Agent Loop 产品化

版本：v1.0 · 日期：2026-09-28 · 来源：conatus_agent `plan.dart` / `reflection.dart` / `router.dart` / `agent_loop.dart`
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

## 5. 有意偏离

（无。）

## Swiftus 实现注记

- `Plan` / `PlanStep` 为 Sendable struct，JSON 形状经 `jsonValue` / `init(jsonValue:)` 往返；
- `ReflectionDecision.parse` 的正则用 Swift Regex（大小写不敏感）；
- `Reflector` / 路由 existential 均为 `@ContextTreeActor`；`RouteDecision` 为带关联值 enum；
- AgentLoop.Config 增补 `planning` / `reflector` / `router`；`buildSystemText` 的 `SystemTextInput` 增补计划段（planSection）。
