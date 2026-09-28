# S15 · AWS SigV4 签名链

版本：v1.0 · 日期：2026-09-28 · 来源：conatus_credentials `credentials_sigv4.dart` + AWS 官方《Signature Version 4 signing process》文档示例
语言中立规格。Swiftus 实现注记见文末。
前置：S12（凭据值对象与来源）。
范围说明：只覆盖 `Authorization` 头签法（**非** presigned URL），算法固定 `AWS4-HMAC-SHA256`。SigV4 是 AWS Secrets Manager 等只读远端凭据来源的签名底座（S12 §7），本身不直接对外暴露工具。

## 1. 词汇

- `SigV4Signer`：不可变签名器，构造参数 `accessKey`（`AKIA…` / `ASIA…`）、`secretKey`、`region`、`service`、可选 `sessionToken`（临时凭证）；
- `sign(method, uri, headers, payload, timestamp) -> headers`：对一次请求签名，返回**可原样发送**的完整头表；
- `amzDate`：UTC 紧凑时刻 `YYYYMMDDTHHMMSSZ`（年补齐四位，月日时分秒各补零两位）；`dateStamp` 取其前 8 位；
- `scope`：`dateStamp/region/service/aws4_request`；
- 参与签名的头集合（**SignedHeaders**）：调用方业务头**键小写化**后，加上系统头 `host`（取自 URI 的 host，**不写回结果**但一定参与签名）、`x-amz-date`、`x-amz-content-sha256`、可选 `x-amz-security-token`；同名时**系统头覆盖业务头**。

## 2. 规范请求（canonical request）

六段以 `\n` 相连，顺序固定：

1. HTTP 方法（**原样**，调用方给什么就用什么，不做大写化）；
2. 规范 URI（canonical URI，见 §3）；
3. 规范查询串（canonical query，见 §4；无查询时为空串，该段仍占一行）；
4. 规范头段：SignedHeaders 中每个头一行 `小写名:trim(值)`，行尾 `\n`，**整段以一个额外换行结束**（即 `headers\n`）；
5. SignedHeaders：头名**升序**以 `;` 相连；
6. 载荷哈希：`sha256(payload)` 的小写十六进制（空载荷即空串的 sha256）。

## 3. 规范 URI

- 取 URI 的路径**按 `/` 切段**（保留空段），**逐段解码**后再按 RFC 3986 unreserved 集（`A-Za-z0-9-._~`）逐段编码，以 `/` 连接；解码再编码的目的是避免对已编码的段二次编码（`%20` 不得变成 `%2520`）；
- 路径为空 → `/`；`/a/` → `/a/`（尾斜杠是空段，原样保留）；`//a` → `//a`（首空段原样保留）；`/a//b` → `/a//b`；
- 路径中的 `+` 是字面量（**不**当作空格），编码为 `%2B`；非 ASCII 段按 UTF-8 字节逐字节百分号编码。

## 4. 规范查询串

- 原始查询串按 `&` 切分，每段按**首个** `=` 切成键与值（无 `=` 时值为空串）；
- 键与值各自**先解码再编码**：解码时 `+` 视为空格（application/x-www-form-urlencoded 语义），随后按 §3 的 unreserved 集编码（空格 → `%20`，`=` → `%3D`）；
- 展开为若干 `k=v` 串后**按整串字典序排序**（不是按键分组：同键多值按值排序，`?a=2&a=1` → `a=1&a=2`；大小写敏感，`?a=1&A=2` → `A=2&a=1`），以 `&` 连接。

## 5. 签名链

1. `kDate = HMAC-SHA256(key: "AWS4" + secretKey, msg: dateStamp)`
2. `kRegion = HMAC(kDate, region)`
3. `kService = HMAC(kRegion, service)`
4. `kSigning = HMAC(kService, "aws4_request")`

- 待签串（string to sign）：`"AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + sha256Hex(规范请求)`；
- `signature = hex(HMAC-SHA256(kSigning, 待签串))`。

## 6. 输出头表

`sign` 返回 = 业务头（**保留调用方原大小写**）+ 下列生成头：

- `X-Amz-Date`: amzDate；
- `X-Amz-Content-Sha256`: 载荷哈希；
- `X-Amz-Security-Token`: sessionToken（缺省不带该键）；
- `Authorization`: `AWS4-HMAC-SHA256 Credential=<accessKey>/<scope>, SignedHeaders=<小写升序以 ; 相连>, Signature=<signature>`。

`Host` 不出现在返回头表（HTTP 客户端按 URI 自动发送），但一定进入 SignedHeaders。

## 7. 确定性

时间戳由调用方**显式传入**（生产用当前 UTC），因此同一输入必然得到同一输出；同一签法器重复签名结果逐字节相同。

## 8. 官方向量交叉校验

签名正确性不能只靠「与 Dart 一致」自证，故另取 **AWS 官方文档的签名示例**做第三方交叉：GET `https://example.amazonaws.com/`，仅 `Host` + `X-Amz-Date: 20150830T123600Z`，空载荷，`accessKey=AKIDEXAMPLE`、`secretKey=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`、`region=us-east-1`、`service=service`；期望 `Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31`。

纪律：**只锁定能被第三方独立实现复算出来的常量**——凭记忆写下的官方向量若复算不一致，一律丢弃该向量而不是改期望值（移植期已在 S3/S8 踩过同类坑）。

## 9. 有意偏离

- **非法百分号转义**：Dart 的 `Uri.decodeComponent` 遇非法转义抛 `FormatException`；Swift 的 `removingPercentEncoding` 返回空，签名器改为**保留原始文本**继续计算（不抛错）。输入侧约定为合法编码，非法输入的差异记在此处。
- **HTTP 客户端**：Dart 用 `package:http`，本规格只定义签名与其头表，传输由调用方负责（Swift 侧统一 URLSession，见 S12 §7）。

## Swiftus 实现注记

- `SigV4Signer` 为 Sendable struct（值类型签名器，可跨域共享）；HMAC / SHA256 走系统 `CryptoKit`（不引第三方依赖，AGENTS 已定 CryptoKit 为 SigV4 的既定选择）；
- 规范 URI / 查询串的「解码再编码」不复用 Foundation 的 `URL.path` / `queryItems`（前者会把 `%2F` 解成 `/`、后者不把 `+` 当空格），改为**自取 `URLComponents.percentEncodedPath` / `percentEncodedQuery` 后手工解码再编码**，以与 Dart 语义逐段对齐；
- 百分号编码的 allowed 集合显式写死为 ASCII unreserved 集（`CharacterSet.alphanumerics` 含非 ASCII 字母，会漏编码）；
- 官方向量测试与 Dart 行为 fixtures 并存：前者锁算法正确性，后者锁两端行为一致。
