/// SwiftusAgent：Agent Loop 核心闭环（规格 S4 §6）。
///
/// 当前刀范围：AgentLoop（run / 取消竞速 / 压缩窗口 / system 装配）+
/// 事件派生（deriveAgentMessages / 编解码）+ 「模型可见即已记录」不变式 +
/// SessionLogRecorder / SessionLogLlmProvider / 工具埋点 + provideAgentLoop。
///
/// 随后续刀接入：plan / sub-agent / reflection / router / telemetry / eval /
/// approval / skill 沉淀 / recovery / goal 续行 / autonomous schedule。
