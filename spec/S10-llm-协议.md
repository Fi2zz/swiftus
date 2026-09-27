# S10 · LLM 协议

版本：v1.0 · 日期：2026-09-27 · 来源：conatus_llm `llm.dart` / `llm_openai.dart`
语言中立规格。Swiftus 实现注记见文末。

## 1. 形态与端点

- OpenAI 兼容双形态：`chat` → `{baseUrl}/chat/completions`（消息用 `messages`）；`responses` → `{baseUrl}/responses`（消息用 `input`，并显式 `store: false`，避免敏感原文留存服务端）。
- 请求头：`Content-Type: application/json`、`Authorization: Bearer {apiKey}`、`User-Agent`（可伪装成其他 harness 客户端）。

## 2. 消息模型（LlmMessage）

- `role`：system / user / assistant / tool；`content`：文本。
- `toolCalls`：助手消息请求的工具调用（id / name / arguments 原始 JSON 串，未解析）。
- `toolCallId`：工具结果消息（role=tool）对应的调用 id。
- `images`：多模态输入（mimeType + base64），data URL 形式 `data:{mime};base64,{data}` 两形态共用。
- `cacheable`：可缓存稳定前缀的**纯本地标记**，不写入请求体（前缀缓存由服务端自动生效，塞入非标字段可能被拒）。

## 3. 请求体

- 公共：`model`；`stream: true`（见 §5：非流式签名也走流式端点）；`options` 并入并覆盖顶层字段。
- chat：`messages: [message.toJson()]`；流式另带 `stream_options: {include_usage: true}`。
- responses：`input: [...]`（§4）、`store: false`。
- tools 投影（非空才下发）：chat 形态 `{type: 'function', function: {name, description, parameters}}`；responses 形态扁平 `{type: 'function', name, description, parameters}`。输入仅为 `{name, description, parameters}` 白名单三键。

## 4. Responses input 项映射

- role=tool → `{type: 'function_call_output', call_id, output}`。
- 助手消息带 toolCalls：content 非空时先产一个 message 项，再为每个调用产 `{type: 'function_call', call_id, name, arguments}`。
- 普通 message 项：`{type: 'message', role, content: [...]}`；assistant 历史项另须 `status: 'completed'`；文本内容类型 assistant 为 `output_text`、其余 `input_text`；图片为 `input_image` + data URL。

## 5. 流式签名与 streamChatResult

- `chatStream` 产出流式事件；`chat`（非流式签名）实际也走流式端点，由 `streamChatResult` 把增量累积成一次结果——**思考过程不丢失**。
- 流式事件三类：`textDelta`（正文增量）、`reasoningDelta`（思考增量）、`done`（终态，一次）。
- `done` 携带：`usage`（累计用量）、`finishReason`、`toolCalls`（工具参数以 JSON 分片到达，**终态一次性给出**）、`provider`、`model`。
- `streamChatResult` 累积 text / reasoning，从 done 取 toolCalls / usage / model；`onEvent` 逐事件透传给宿主（实时渲染）。
- **空流回退**：provider 的 chatStream 一个事件都未产出（如只实现 chat 的测试替身），回退直接调 `chat()`，行为一致。

## 6. SSE 解析

- 只取 `data:` 帧；`event:` / `id:` 等字段忽略；`:` 开头为注释行，忽略。
- 多行 `data:` 以换行拼接；空行成帧；帧尾 `data: [DONE]` 终止（终止前冲刷已攒帧）。
- 字节流不按行到达（坑 #4）：行边界由解析层跨块拼接。

## 7. Chat 帧解析（choices 增量）

- `usage` 出现即覆盖；`choices` 为空忽略。
- 取 `choices[0].delta`：`reasoning_content` 非空 → reasoning 增量；`content` 非空 → text 增量；`finish_reason` 出现即更新。
- `delta.tool_calls` 按 `index` 累积：首个分片通常带 `id` 与 `function.name`，后续只补 `arguments` 分片；`arguments` 非字符串（已解析对象）按 JSON 编码拼接。

## 8. Responses 帧解析（事件 type 分派）

- `response.output_text.delta` → text 增量（空串忽略）。
- `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` → reasoning 增量。
- `response.output_item.added` / `.done`：`function_call` 项收 `call_id` / `name` / `arguments`（done 帧 arguments 为权威完整值，覆盖已累积分片；空串不覆盖）。
- `response.function_call_arguments.delta` → 追加；`.done` → 完整覆盖（空串忽略，不抹掉已累积分片）。
- `response.completed` / `.incomplete`：取 `response.usage`；finishReason：incomplete → `'length'`，否则 `response.status`（缺省 `'completed'`）。
- `response.failed`：抛错（`流式响应失败：{error.message ?? 'unknown'}`）。

## 9. 工具调用汇总

- 汇总已完成的调用；**丢弃只收到分片、始终无名的占位项**。
- `arguments` 累积为空时回退 `'{}'`。

## 10. 错误形态（LlmException：provider / message / statusCode?）

- 请求超时：`请求超时（{seconds}s）`；网络错误：`网络错误：{message}`。
- 非 200：message 为响应 body，附 statusCode。
- 缺 API Key：`缺少 API Key`；配置了凭据键时 `缺少 API Key（凭据键：{key} 未配置）`。

## 11. FallbackLlm（顺序回退链）

- 非流式与流式都按顺序尝试，任一成功即返回；全部失败抛 `LlmException('fallback', '所有提供商均失败：\n{逐 provider 错误}')`。
- **流式回退只在尚未产出任何事件时生效**；一旦产出过增量，中途失败直接上抛（已产出内容无法收回）。
- `close()` 级联关闭全部 provider。

## 12. 凭据联动与装配

- 构造期解析顺序：显式 `apiKey` → 凭据服务 `get(credentialKey)` → 空串（**不直接读环境变量**；需要 env 时用 EnvCredentials 作来源）。
- 凭据变更推送驱动 Key 就地轮换：键不匹配忽略、已过期忽略；轮换只改 apiKey，**不重建 HTTP 客户端**。
- `provideLlm(ctx, llm:)`：以 `'llm'` 服务键提供 FallbackLlm；`close()` 随上下文释放登记。

## Swiftus 实现注记（偏离记录）

- 动态 JSON（options / usage / 请求体）统一 `JSONValue`（方案书 §5.2）；请求体以 JSONValue 构建后 JSONSerialization 落笔。
- HTTP 层 `package:http` → URLSession；SSE 用 URLSession bytes 的行序列跨块拼接（对应 §6 口径）。
- 超时用 URLRequest `timeoutInterval` 承载（Dart 是对 send 的整段 await 超时；URLSession 的请求超时口径略有差异，暂记，必要时改 Task 竞速）。
- 凭据变更推送见 S12 注记（broadcast Stream → 域内同步监听列表）。
