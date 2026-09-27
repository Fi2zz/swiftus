# S14 · Skill catalog

版本：v1.0 · 日期：2026-09-27 · 来源：conatus_skill 全包（**目录监听 skill_filesystem_watch 暂缓，W1 用手动 refresh 代替**）
语言中立规格。Swiftus 实现注记见文末。

## 1. 技能名与来源标签

- 技能名：kebab-case，模式 `^[a-z0-9]+(?:-[a-z0-9]+)*$`；provider 名与运行时技能名同规则。
- 来源标签与发现根权重：`project-conatus`（项目根 `.conatus/skills`，rank 100）、`project-agents`（`.agents/skills`，200）、`runtime`（宿主注册，250）、`user-conatus`（`$CONATUS_HOME/skills`，缺省 `~/.conatus/skills`，400）、`user-agents`（`$CONATUS_AGENTS_HOME/skills`，缺省 `~/.agents/skills`，500）、`custom`（调用方显式目录）。
- 项目根：最近的含 `.git` 的祖先目录；找不到回退为起始目录。

## 2. SKILL.md 解析（parseSkillDocument）

- frontmatter：首行必须是 `---`（容忍行尾 CR），到下一个 `---` 行为止；缺首行 → `缺少 frontmatter：首行必须是 ---`。正文 = 剩余部分 trim。
- YAML 必须解析为键值映射，否则 → `frontmatter 不是合法 YAML：…` / `frontmatter 必须是键值映射`。
- **旧键整条丢弃**：出现 `disableModelInvocation` / `modelInvocable` / `userInvocable` → `frontmatter 用了旧键 "x"，请改用规范键`。
- `name`：缺失或非 kebab-case → `name 缺失或不是 kebab-case 技能名`；`description`：缺失或 trim 后为空 → `description 缺失或为空`。
- `disable-model-invocation` 布尔文法：bool 直取；num 仅 1 / 0；字符串 trim + 小写后 `true/yes/on/1` 与 `false/no/off/0`；其余 → `不是合法布尔值：x`（整条丢弃）。`modelInvocable = !disable`。
- `whenToUse`：可选文本，trim 后为空视为未声明；`metadata`：映射则原样保留。

## 3. 发现与层内排序（filesystem provider）

- **只扫一层**：发现根下列举不递归；目录条目取其中的 `SKILL.md`（存在才取），文件条目取 `*.md`；条目按路径码位序处理后输出。
- 发现根读取失败（不存在等）→ 该根产出为空；条目解析失败经 onWarning 上报（`技能文件 x 被忽略：…` / `读取失败：…`）并跳过。
- 候选收敛：按「rank → provider 注册顺序 → provider 内产出顺序」排序，**同名只留第一个**，被遮蔽者上报 `技能 "name" 被 {winner.provider} 遮蔽：{loser.source} 的候选被忽略。`；结果按技能名码位升序。
- 单个 provider 抛错只经 onWarning 上报（`技能 provider "name" 列举失败：…`），其余 provider 产出照常；运行时技能以 rank 250 参与同一轮排序。

## 4. 注册表（SkillRegistry）

- `available`：当前可用技能的**同步快照**（含继承，名字码位升序）；`modelInvocable` 为其过滤子集。
- `registerProvider`：provider.name 必须是技能名格式、注册表内唯一（`技能 provider "name" 已注册。`）；`register(registration)`：kebab-case 名、description 非空、唯一（`运行时技能 "name" 已注册。`）。已释放注册表再注册抛 `技能注册表已释放，无法再注册。`
- `onChange`：快照确有变化才通知（逐字段相同的重复收集不通知）。
- `refresh()`：立即收集；**收集期间的并发调用共用同一次**，期间再次失效在本轮结束后补一轮。`invalidate()`：合并窗口（默认 50ms）内的密集失效只收集一次。
- `load(name)`：只认当前可见集合——非技能名 / 不可见 / 已消失返回空；自身快照没有的名字委托父级；runtime 技能直接产定义；provider 加载返回空时失效缓存并返回空。
- `dispose`：取消待执行的收集、父级级联与全部监听；幂等。

## 5. 父子作用域

- 子注册表（`parent:` + `visible:`）把父级快照经 visible 过滤（缺省全继承）后并入 available；**同名由子级赢下**，被覆盖的父级条目上报 `技能 "name" 被本作用域覆盖：{shadowed.source} 的候选被忽略。`
- 父级变化级联到子级：只重新合并已有快照，**不重跑子级 provider**。

## 6. 目录渲染与挂载

- 渲染（`renderSkillCatalog`）：`<system-reminder>` 包裹——引导句、`<available_skills>` 每行 `- \`name\`: desc`（desc 折叠空白、超过 500 截断补 `...`、`&` `<` `>` 转义）、收尾指令（模型须先调 `skill` 工具加载、目录只含摘要不得推断执行）。
- 目录段（`SkillCatalogSection`）：段名 `skills`、order 50；跟随注册表 onChange 同步；**空目录摘除该段**（prompt 与无插件时逐字相同）。

## 7. `skill` 工具（SkillLoadTool）

- 参数：`name` 必填（描述：The exact skill name from the available skills list）。
- 非法名 → `SKILL_UNAVAILABLE` / `invalid skill name "x"`；命中快照但不可模型调用 → `SKILL_UNAVAILABLE` / `skill "x" is not available for model invocation`；加载不到 → `SKILL_UNKNOWN` / `skill "x" is unknown or no longer available`。失败 content 为 JSON `{code, message}`。
- 成功：渲染 `<skill_content>`（§8），value 为 `{name, provider, content}`。

## 8. skill_content 渲染

- `<skill_content name="...">`（name 转义 `&` `"` `<`）；`<skill_resources>` 按资源基址给提示（directory：相对路径先按基目录取址；url：相对地址按基 URL 取址；opaque：描述原文；无基址：由 provider 管理），固定尾句 `Load referenced resources only as needed.`；`<skill_instructions>` 为正文。

## 9. 装配

- `provideSkillRegistry(ctx, providers:, inlineSkills:, registry:)`：`'skillRegistry'` 服务键；providers / inlineSkills 以 `ctx.effect` 登记（随上下文卸载撤销）；dispose 随上下文释放；**完成首次 refresh 后返回**（async）。
- `provideSkillCatalog(ctx)`：require skillRegistry 与 systemPrompt，`ctx.effect(section.attach)`。
- `provideSkillTool(ctx, tools:, name:)`：注册到工具表（缺省 `ctx.tools`）。
- `provideSkillFilesystem(ctx, roots:, watch:, debounce:)`：注册目录发现 provider 并 refresh；**目录监听本版不实现**（watch 参数保留但不生效，见注记）。

## Swiftus 实现注记（偏离记录）

- **目录监听暂缓**：Dart 用原生目录监听（FSEvents 对应物）+ 250ms 合并窗口触发 invalidate；W1 不实现监听，技能变更以手动 `refresh()` 代替；落地时补 `SkillRootWatcher` 并回写本节。
- frontmatter 的 YAML 用 **Yams** 解析（方案书外部依赖最小集之一；SwiftusSkill 的唯一外部依赖）。
- 快照相等判定：`SkillSummary` 直接 Equatable（JSONValue 字典无序等价），替代 Dart 的 jsonEncode 字符串比较——语义等价且不受键序影响。
- 合并窗口与监听注销均为域内令牌 / Task（时钟纪律同 S5 注记，Clock 统一后回接）。
- 监听器的移除由闭包身份改为令牌（同 S1 注记）。
