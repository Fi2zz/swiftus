# S3 · Session 事件格式

版本：v0.1（**部分：仅脱敏一节**） · 日期：2026-09-27 · 来源：conatus_core `redaction.dart`
语言中立规格。事件格式主体（字段、seq 分配、append-only）随 session 领域动工补全；脱敏规则因实现落在 core，先行沉淀。

## 1. 敏感键判定（isSensitiveKey）

键名命中任一规则即视为凭据字段，大小写不敏感，兼容下划线 / 连字符 / 驼峰：

- **规范化命中**：键名转小写并剔除非 `[a-z0-9]` 字符后，命中敏感词元表；
- **分段命中**：键名按非字母数字切分，任一段命中敏感词元表（如 `ARK_API_KEY` → `ark` + `api` + `key`）。

敏感词元表：`key` / `apikey` / `token` / `secret` / `password` / `passwd` / `authorization` / `credential` / `credentials` / `privatekey` / `accesskey` / `secretkey`。

- 简单复数视同命中：词元加尾 `s`（`keys` / `tokens` / `secrets` …）。
- 规范化后为空串：不敏感。

## 2. 脱敏表示（maskSecret）

- 空串 → 空串；
- 长度 ≤ 8 → 等长全星号（短密钥不做局部保留，避免近乎完整暴露）；
- 长度 > 8 → 前 4 位 + `...` + 后 4 位。
- 「长度」与「取位」按 UTF-16 码元计（与 Dart `String.length` 对齐；ASCII 凭据无差异）。

## 3. 递归脱敏（redactSecrets）

- 输入为动态 JSON（object / array / string / number / bool / null），**不修改入参**，返回新值；
- object：值递归脱敏；键名命中敏感键时，其值改为遮蔽表示——字符串值走 `maskSecret`，非字符串非 null 值（数字、对象等）替换为 `***`，null 保持 null；
- array：逐元素递归；
- 其余标量：原样返回。

## Swiftus 实现注记

- 动态 JSON 载体为 `JSONValue` 枚举（方案书 §5.2），`redactSecrets(JSONValue) -> JSONValue`。
