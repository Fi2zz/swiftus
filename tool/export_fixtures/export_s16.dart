// S16 Agent Loop 产品化 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法见 tool/export_fixtures/README.md。脚本化模型为导出器内置替身。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_agent/conatus_agent.dart';
import 'package:conatus_foundation/conatus_foundation.dart';
import 'package:conatus_llm/conatus_llm.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'plan': _plan,
    'reflection': _reflection,
    'router-flow': _routerFlow,
    'planning-phase': _planningPhase,
  };
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, Future<Map<String, Object?>> Function()> entry
      in fixtures.entries) {
    File('${outDir.path}/${entry.key}.json')
        .writeAsStringSync('${encoder.convert(await entry.value())}\n');
    stdout.writeln('导出 ${entry.key}.json');
  }
}

Directory _outputDir() {
  final Directory here = File.fromUri(Platform.script).parent;
  return Directory('${here.parent.parent.path}/spec/fixtures/s16');
}

// ───────────────────────────── plan ─────────────────────────────

/// kind = plan：plan_write 执行 → readPlan / planSection / 事件；两条覆盖取最新。
Future<Map<String, Object?>> _plan() async {
  final Session session = Session(id: 's1');
  final ToolRegistry tools = ToolRegistry()..register(PlanTool(session: session));
  final ToolResult first = await tools.call(ToolCall(name: kPlanToolName, arguments: <String, Object?>{
    'goal': '写一份报告',
    'steps': <Object?>['收集资料', '', '  撰写  ', '校对'],
  }));
  final Map<String, Object?> writeRead = <String, Object?>{
    'label': '写入并读取（空步骤跳过，id 跳号）',
    'expect': <String, Object?>{
      'content': first.content,
      'value': first.value,
      'plan': readPlan(session)?.toJson(),
      'section': planSection(session),
      'eventType': session.events.last.type,
    },
  };
  await tools.call(ToolCall(name: kPlanToolName, arguments: <String, Object?>{'goal': '新目标'}));
  final Map<String, Object?> latest = <String, Object?>{
    'label': '两条 plan/updated 取最后一条',
    'expect': <String, Object?>{'goal': readPlan(session)?.goal},
  };
  final Map<String, Object?> empty = <String, Object?>{
    'label': '无计划时 planSection 为空串',
    'expect': <String, Object?>{'section': planSection(Session(id: 's2'))},
  };
  return <String, Object?>{
    'name': 'plan',
    'kind': 'plan',
    'cases': <Object?>[writeRead, latest, empty],
  };
}

// ───────────────────────────── reflection ─────────────────────────────

/// kind = reflection：决策解析 / shouldReflect 矩阵 / reflectAndRetry 端到端。
Future<Map<String, Object?>> _reflection() async {
  return <String, Object?>{
    'name': 'reflection',
    'kind': 'reflection',
    'decisionCases': <Object?>[
      _decisionCase('{"decision":"retry","reason":"x"}'),
      _decisionCase('{"decision": "Replan"}'),
      _decisionCase('先 retry 再说'),
      _decisionCase('replan'),
      _decisionCase('看起来没问题'),
    ],
    'shouldReflectCases': _shouldReflectCases(),
    'retryCase': await _retryCase(),
    'replanCase': await _replanCase(),
  };
}

Map<String, Object?> _decisionCase(String text) => <String, Object?>{
      'input': text,
      'expect': ReflectionDecision.parse(text).action.name,
    };

List<Map<String, Object?>> _shouldReflectCases() {
  final Tool low = _FixedTool('readonly', ToolRisk.low);
  final Tool medium = _FixedTool('write', ToolRisk.medium);
  final ToolResult ok = ToolResult.success('好');
  final ToolResult bad =
      ToolResult.failure('坏', error: const ToolError('X', 'bad'));
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];
  for (final ReflectionStrategy strategy in ReflectionStrategy.values) {
    for (final (Tool, ToolResult) pair in <(Tool, ToolResult)>[
      (low, ok),
      (low, bad),
      (medium, ok),
    ]) {
      final Reflector reflector =
          Reflector(llm: _ScriptedProvider(const <LlmResult>[]), strategy: strategy);
      cases.add(<String, Object?>{
        'strategy': strategy.name,
        'risk': pair.$1.riskLevel.name,
        'failed': pair.$2.isError,
        'expect': reflector.shouldReflect(pair.$1, pair.$2),
      });
    }
  }
  return cases;
}

/// retry 路径：初次失败 → 反思 retry → 重跑成功；反思第二次 continue 停。
Future<Map<String, Object?>> _retryCase() async {
  final _ScriptedProvider llm = _ScriptedProvider(<LlmResult>[
    _text('{"decision":"retry"}'),
    _text('{"decision":"continue"}'),
  ]);
  final Reflector reflector =
      Reflector(llm: llm, strategy: ReflectionStrategy.always, maxRetries: 1);
  final ToolRegistry tools = ToolRegistry()..register(_FixedTool('probe', ToolRisk.low));
  const LlmToolCall call = LlmToolCall(id: 'c1', name: 'probe');
  int invocations = 0;
  final ToolResult outcome = await reflectAndRetry(
    reflector: reflector,
    tools: tools,
    task: '任务',
    call: call,
    initial: ToolResult.failure('bad', error: const ToolError('X', 'bad')),
    invoke: (LlmToolCall _) async {
      invocations += 1;
      return ToolResult.success('ok');
    },
  );
  return <String, Object?>{
    'expect': <String, Object?>{
      'invocations': invocations,
      'content': outcome.content,
      'reflectCalls': llm.calls.length,
    },
  };
}

/// replan 路径：onReplan 置位、不重跑；maxRetries 外不再反思。
Future<Map<String, Object?>> _replanCase() async {
  final _ScriptedProvider llm =
      _ScriptedProvider(<LlmResult>[_text('{"decision":"replan"}')]);
  final Reflector reflector =
      Reflector(llm: llm, strategy: ReflectionStrategy.always);
  final ToolRegistry tools = ToolRegistry()..register(_FixedTool('probe', ToolRisk.low));
  const LlmToolCall call = LlmToolCall(id: 'c1', name: 'probe');
  int invocations = 0;
  bool replanned = false;
  final ToolResult outcome = await reflectAndRetry(
    reflector: reflector,
    tools: tools,
    task: '任务',
    call: call,
    initial: ToolResult.failure('bad', error: const ToolError('X', 'bad')),
    invoke: (LlmToolCall _) async {
      invocations += 1;
      return ToolResult.success('ok');
    },
    onReplan: () => replanned = true,
  );
  return <String, Object?>{
    'expect': <String, Object?>{
      'invocations': invocations,
      'replanned': replanned,
      'content': outcome.content,
    },
  };
}

// ───────────────────────────── router 集成 ─────────────────────────────

/// kind = router-flow：AgentLoop 路由三态（reply 不调模型 / tools 预置后模型收口 /
/// pass 落模型）。
Future<Map<String, Object?>> _routerFlow() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];
  final _ScriptedProvider replyLlm = _ScriptedProvider(<LlmResult>[_text('不该被调用')]);
  final AgentLoop replyLoop = AgentLoop(
    llm: replyLlm,
    tools: ToolRegistry()..register(_FixedTool('get_time', ToolRisk.low)),
    router: _FixedRouter(const RouteDecision.reply('本地直答')),
  );
  final AgentTurn replyTurn = await replyLoop.run('你好');
  cases.add(<String, Object?>{
    'label': 'reply 直答不调模型',
    'expect': <String, Object?>{
      'reply': replyTurn.reply,
      'modelCalls': replyLlm.calls.length,
    },
  });

  final _ScriptedProvider toolsLlm = _ScriptedProvider(<LlmResult>[_text('现在是 12:00')]);
  final AgentLoop toolsLoop = AgentLoop(
    llm: toolsLlm,
    tools: ToolRegistry()..register(_TimeTool()),
    router: _FixedRouter(const RouteDecision.tools(
        <LlmToolCall>[LlmToolCall(id: 'c1', name: 'get_time')])),
  );
  final AgentTurn toolsTurn = await toolsLoop.run('现在几点');
  final List<LlmMessage> second = toolsLlm.calls.first;
  cases.add(<String, Object?>{
    'label': 'tools 预置执行后模型收口',
    'expect': <String, Object?>{
      'reply': toolsTurn.reply,
      'modelCalls': toolsLlm.calls.length,
      'lastRoles': <String>[for (final LlmMessage m in second) m.role],
      'toolContent': second.last.content,
    },
  });

  final _ScriptedProvider passLlm = _ScriptedProvider(<LlmResult>[_text('模型回答')]);
  final AgentLoop passLoop = AgentLoop(
    llm: passLlm,
    tools: ToolRegistry(),
    router: _FixedRouter(const RouteDecision.pass()),
  );
  final AgentTurn passTurn = await passLoop.run('你好');
  cases.add(<String, Object?>{
    'label': 'pass 落模型',
    'expect': <String, Object?>{
      'reply': passTurn.reply,
      'modelCalls': passLlm.calls.length,
    },
  });
  return <String, Object?>{
    'name': 'router-flow',
    'kind': 'router-flow',
    'cases': cases,
  };
}

// ───────────────────────────── 规划轮 ─────────────────────────────

/// kind = planning-phase：planning=true 且注册了 plan_write → 先规划后执行；
/// 未注册 plan_write → 不跑规划轮。
Future<Map<String, Object?>> _planningPhase() async {
  final Session session = Session(id: 's1');
  final ToolRegistry tools = ToolRegistry()
    ..register(PlanTool(session: session))
    ..register(_TimeTool());
  final _ScriptedProvider llm = _ScriptedProvider(<LlmResult>[
    LlmResult(content: '', provider: 'scripted', model: 'm', toolCalls: <LlmToolCall>[
      LlmToolCall(
          id: 'c1',
          name: kPlanToolName,
          arguments: '{"goal":"报时","steps":["问时间","回答"]}'),
    ]),
    _text('12:00'),
  ]);
  final AgentLoop loop = AgentLoop(
    llm: llm,
    tools: tools,
    session: session,
    planning: true,
  );
  final AgentTurn turn = await loop.run('现在几点');
  final Map<String, Object?> planned = <String, Object?>{
    'label': '先规划后执行',
    'expect': <String, Object?>{
      'reply': turn.reply,
      'modelCalls': llm.calls.length,
      'firstCallTools': <String>[
        for (final Map<String, Object?> schema in llm.firstTools ?? <Map<String, Object?>>[])
          '${schema['name']}',
      ],
      'planGoal': readPlan(session)?.goal,
      'systemHasPlan': llm.calls.last.first.content.contains('[当前计划]'),
      'eventTypes': <String>[for (final SessionEvent e in session.events) e.type],
    },
  };

  final _ScriptedProvider noToolLlm = _ScriptedProvider(<LlmResult>[_text('直接回答')]);
  final AgentLoop noToolLoop = AgentLoop(
    llm: noToolLlm,
    tools: ToolRegistry(),
    session: Session(id: 's2'),
    planning: true,
  );
  final AgentTurn noToolTurn = await noToolLoop.run('你好');
  final Map<String, Object?> skipped = <String, Object?>{
    'label': '未注册 plan_write 不跑规划轮',
    'expect': <String, Object?>{
      'reply': noToolTurn.reply,
      'modelCalls': noToolLlm.calls.length,
    },
  };
  return <String, Object?>{
    'name': 'planning-phase',
    'kind': 'planning-phase',
    'cases': <Object?>[planned, skipped],
  };
}

// ───────────────────────────── 替身 ─────────────────────────────

LlmResult _text(String content) =>
    LlmResult(content: content, provider: 'scripted', model: 'm');

/// 导出器内置的脚本化模型（记录调用与首轮工具表）。
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this.script);

  final List<LlmResult> script;
  final List<List<LlmMessage>> calls = <List<LlmMessage>>[];
  List<Map<String, dynamic>>? firstTools;
  int _count = 0;

  @override
  String get name => 'scripted';

  @override
  Future<LlmResult> chat(List<LlmMessage> messages,
      {Map<String, dynamic>? options, List<Map<String, dynamic>>? tools}) async {
    calls.add(List<LlmMessage>.of(messages));
    firstTools ??= tools;
    final int index = _count < script.length ? _count : script.length - 1;
    _count += 1;
    return script[index];
  }

  @override
  Stream<LlmStreamEvent> chatStream(List<LlmMessage> messages,
          {Map<String, dynamic>? options, List<Map<String, dynamic>>? tools}) =>
      const Stream<LlmStreamEvent>.empty();

  @override
  void close() {}
}

/// 固定风险级的探针工具。
class _FixedTool extends Tool {
  _FixedTool(this.toolName, this.risk);

  final String toolName;
  final ToolRisk risk;

  @override
  String get name => toolName;
  @override
  String get description => toolName;
  @override
  ToolRisk get riskLevel => risk;
  @override
  Future<ToolResult> call(ToolContext ctx) async => ToolResult.success('ok');
}

/// 固定时间工具。
class _TimeTool extends Tool {
  @override
  String get name => 'get_time';
  @override
  String get description => '返回当前时间';
  @override
  Future<ToolResult> call(ToolContext ctx) async => ToolResult.success('12:00');
}

/// 固定路由决策的路由器。
class _FixedRouter implements Router {
  const _FixedRouter(this.decision);

  final RouteDecision decision;

  @override
  Future<RouteDecision> route(String input) async => decision;
}
