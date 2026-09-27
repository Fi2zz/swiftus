# S6 · Prompt 装配

版本：v1.0 · 日期：2026-09-27 · 来源：conatus_foundation `system_prompt.dart` / `prompt_types.dart`
语言中立规格。Swiftus 实现注记见文末。

## 1. 词汇

- `PromptSection`：`name`（唯一，重复注册抛错）、`order`（排序权重，升序，缺省 0）、`text`（段文本 provider，**每次装配都重新求值**，可引用 `{{variable}}` 占位符）。
- `PromptContext`：同段结构，装配为独立的动态上下文贡献项；空串不贡献内容。
- `AssembledSection` / `AssembledContext`：已解析（尚未插值）的名字 + 文本。
- `PromptAssembly`：一次装配的完整结果——已排序的段、上下文与插值变量。

## 2. 注册

- `section(section)` / `context(context)`：同名重复注册抛错（`prompt 段 "name" 已注册` / `prompt 上下文 "name" 已注册`，段与上下文各自独立命名空间）；返回幂等 Disposer。
- `add(text, name:)`：用纯文本创建并注册段；`name` 缺省时自动生成 `add-N`——单调递增、remove 后不复用、跳过仍占用名；返回段句柄供 `remove` 使用。
- `remove(section)`：幂等，返回是否确实移除。

## 3. 装配与排序

`assemble(variables:)`：段与上下文分别按 **order 升序、同序按 name 码位序**排序；逐条求值 text provider 产出 Assembled 项；variables 随装配结果携带。

## 4. 渲染与插值

- `render(assembly, separator:)`（缺省 `\n\n`）：段文本插值后按分隔符拼接；**不过滤空文本**。
- `renderContexts(assembly, separator:)`：上下文文本插值后，**空文本不贡献内容**（过滤后拼接）。
- `interpolate(text, variables)`：`{{name}}`（名字为 `[A-Za-z0-9_]+`）替换为 variables 中对应值；**未知占位符原样保留**（含花括号原文）。

## 5. 装配入口

`provideSystemPrompt(ctx, prompt:)`：以 `'systemPrompt'` 服务键提供注册表；`ctx.systemPrompt` 快捷访问。

## 6. time 锚点（本版暂缓）

「time 锚点日粒度与跨天刷新」属 time-context 能力域（foundation），W1 暂不处理；随 time-context 落地时补入本规格并实现（方案书 §四 W1 注记、坑 #3 时区纪律届时生效）。

## Swiftus 实现注记（偏离记录）

- 占位符字符集显式限定为 `[A-Za-z0-9_]`（对齐 Dart `\w`；Swift Regex 的 `\w` 默认含 Unicode 字符，避免放大匹配面）。
- name 码位序在 ASCII 域与 Dart（UTF-16 码元序）一致；非 ASCII 名字存在细微排序差异（占位名与常规段名均为 ASCII，实务无感），暂记。
- provider 闭包为域内同步签名（`@ContextTreeActor () -> String`）；动态上下文需要异步数据时在 provider 内读已落快照的状态（与 Dart 同步 provider 语义一致）。
