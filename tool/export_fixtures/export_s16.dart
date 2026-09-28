// S16 Agent Loop 产品化 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法见 tool/export_fixtures/README.md。脚本化模型为导出器内置替身。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_agent/conatus_agent.dart';
import 'package:conatus_compaction/conatus_compaction.dart';
import 'package:conatus_core/conatus_core.dart';
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
    'telemetry-flow': _telemetryFlow,
    'caching': () async => _caching(),
    'layered-compaction': _layeredCompaction,
    'eval': _eval,
    'approval-flow': _approvalFlow,
    'sub-agent': _subAgent,
    'recovery': _recovery,
    'skill': _skill,
    'goal-flow': _goalFlow,
    'autonomous-flow': _autonomousFlow,
    'plan-mode-flow': _planModeFlow,
    'prompt-evolver-flow': _promptEvolverFlow,
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

// ═══════════════════════ v1.1 增补：观测与缓存 ═══════════════════════

/// telemetry-flow：instrumentTools + TelemetryLlmProvider + AgentLoop onEvent
/// 的端到端事件序列（ms 字段由运行器断言「存在且非负」，不比具体值）。
Future<Map<String, Object?>> _telemetryFlow() async {
  final Context ctx = Context.root();
  final InMemoryTelemetry telemetry = InMemoryTelemetry();
  provideTelemetry(ctx, telemetry: telemetry);
  final ToolRegistry tools = ToolRegistry()..register(_TimeTool());
  provideTools(ctx, tools: tools);
  instrumentTools(ctx);
  final _ScriptedProvider scripted = _ScriptedProvider(<LlmResult>[
    LlmResult(content: '', provider: 'scripted', model: 'm', toolCalls: <LlmToolCall>[
      LlmToolCall(id: 'c1', name: 'get_time'),
    ]),
    _text('12:00'),
  ]);
  final AgentLoop loop = AgentLoop(
    llm: TelemetryLlmProvider(scripted, telemetry: telemetry),
    tools: tools,
    onEvent: (String type, Map<String, Object?> data) =>
        telemetry.emit(TelemetryEvent(type, data: data)),
  );
  await loop.run('现在几点');
  final Map<String, Object?> flow = <String, Object?>{
    'name': 'telemetry-flow',
    'kind': 'telemetry-flow',
    'expect': <String, Object?>{
      'events': <Object?>[
        for (final TelemetryEvent event in telemetry.recent)
          <String, Object?>{'name': event.name, 'data': event.data},
      ],
    },
  };
  ctx.dispose();
  return flow;
}

/// caching：CachePlan 前缀性质 + recordHit 判定 + CachingLlmProvider 透传。
Map<String, Object?> _caching() {
  LlmMessage cached(String text) =>
      LlmMessage('system', text, cacheable: true);
  final CachePlan truncated = CachePlan.of(<LlmMessage>[
    cached('稳定前缀'),
    LlmMessage('user', '不可缓存'),
    cached('不再计入'),
  ]);
  final CachePlan planA = CachePlan.of(<LlmMessage>[cached('前缀A')]);
  final CachePlan planA2 = CachePlan.of(<LlmMessage>[cached('前缀A')]);
  final CachePlan planB = CachePlan.of(<LlmMessage>[cached('前缀B')]);
  final List<Map<String, Object?>> hitCases = <Map<String, Object?>>[];
  for (final Map<String, Object?> usage in <Map<String, Object?>>[
    <String, Object?>{'prompt_cache_hit_tokens': 5},
    <String, Object?>{'cache_hit_tokens': 0},
    <String, Object?>{
      'prompt_tokens_details': <String, Object?>{'cached_tokens': 3}
    },
    <String, Object?>{},
  ]) {
    final ContextCache cache = ContextCache();
    cache.recordHit(plan: planA, usage: usage);
    hitCases.add(<String, Object?>{
      'usage': usage,
      'expect': <String, Object?>{'hit': cache.hits == 1},
    });
  }
  final _ScriptedProvider scripted = _ScriptedProvider(<LlmResult>[
    LlmResult(content: '好', provider: 'scripted', model: 'm',
        usage: <String, dynamic>{'prompt_cache_hit_tokens': 3}),
  ]);
  return <String, Object?>{
    'name': 'caching',
    'kind': 'caching',
    'planCases': <Object?>[
      <String, Object?>{
        'label': '连续前缀遇不可缓存即停',
        'expect': <String, Object?>{
          'cacheableMessages': truncated.cacheableMessages,
          'cacheableChars': truncated.cacheableChars,
          'empty': truncated.empty,
        },
      },
      <String, Object?>{
        'label': '同内容同指纹',
        'expect': <String, Object?>{'same': planA.cacheKey == planA2.cacheKey},
      },
      <String, Object?>{
        'label': '前缀变则指纹变',
        'expect': <String, Object?>{'same': planA.cacheKey == planB.cacheKey},
      },
    ],
    'hitCases': hitCases,
    'passthrough': <String, Object?>{'usage': <String, Object?>{'prompt_cache_hit_tokens': 3}},
  };
}

/// layered-compaction：分层折叠端到端快照。
Future<Map<String, Object?>> _layeredCompaction() async {
  final Session session = Session(id: 's1');
  void user(String text) =>
      session.append(kUserMessageEvent, data: <String, Object?>{'text': text});
  user('记住我喜欢清淡饮食');
  for (int i = 0; i < 6; i++) {
    user('早期闲聊第${i}条');
  }
  session.append(kAssistantMessageEvent, data: <String, Object?>{
    'text': '',
    'toolCalls': <Map<String, Object?>>[
      <String, Object?>{'id': 'c1', 'name': 'search', 'arguments': '{}'},
    ],
  });
  session.append(kToolResultEvent, data: <String, Object?>{
    'callId': 'c1',
    'name': 'search',
    'content': '很长的搜索结果正文第一行\n其余部分省略',
  });
  user('今天吃什么');
  final LayeredCompactor compactor = LayeredCompactor(
    keepRecent: 1,
    classifier: RuleBasedContentClassifier(recentWindow: 2),
  );
  final CompactionResult? result = await compactor.compactIfNeeded(
    session,
    (List<SessionEvent> events, String previous) async =>
        CompactionSummary(events.isEmpty ? '（无早期对话）' : '早期对话要点',
            provider: 'scripted', model: 'm'),
  );
  return <String, Object?>{
    'name': 'layered-compaction',
    'kind': 'layered-compaction',
    'expect': <String, Object?>{
      'summary': result?.summary,
      'shadowedSeqs': result?.shadowedSeqs,
      'kept': result?.kept,
      'invariantViolations': checkCompactionInvariant(session.events),
    },
  };
}

/// eval：默认判分矩阵 + Evaluator 汇总 + 基线对比。
Future<Map<String, Object?>> _eval() async {
  final EvalCase caseA = const EvalCase(
    id: 'a',
    input: '现在几点',
    expectedTools: <String>['get_time'],
    expectedOutput: '12:00',
    maxRounds: 2,
  );
  final EvalResult passResult = const EvalResult(
    caseId: 'a',
    passed: false,
    actualTools: <String>['get_time'],
    actualOutput: '12:00',
    rounds: 1,
    duration: Duration.zero,
  );
  final EvalResult failResult = const EvalResult(
    caseId: 'a',
    passed: false,
    actualTools: <String>[],
    actualOutput: '不知道',
    rounds: 3,
    duration: Duration.zero,
  );
  final List<Map<String, Object?>> judgeCases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '全中通过',
      'expect': defaultEvalJudge(caseA, passResult),
    },
    <String, Object?>{
      'label': '工具缺失/输出不符/超步数均不通过',
      'expect': defaultEvalJudge(caseA, failResult),
    },
  ];

  final _ScriptedProvider scripted = _ScriptedProvider(<LlmResult>[
    LlmResult(content: '', provider: 'scripted', model: 'm', toolCalls: <LlmToolCall>[
      LlmToolCall(id: 'c1', name: 'get_time'),
    ]),
    _text('12:00'),
  ]);
  final AgentLoop loop = AgentLoop(
    llm: scripted,
    tools: ToolRegistry()..register(_TimeTool()),
  );
  final Evaluator evaluator = Evaluator(run: (String input) => loop.run(input));
  final EvalReport report = await evaluator.runAll(<EvalCase>[
    caseA,
    const EvalCase(id: 'b', input: '你好', expectedOutput: '12:00'),
  ]);
  final EvalReport baseline = EvalReport(const <EvalResult>[
    EvalResult(
      caseId: 'a',
      passed: true,
      actualTools: <String>['get_time'],
      actualOutput: '12:00',
      rounds: 1,
      duration: Duration.zero,
    ),
  ]);
  return <String, Object?>{
    'name': 'eval',
    'kind': 'eval',
    'judgeCases': judgeCases,
    'expect': <String, Object?>{
      'results': <Object?>[
        for (final EvalResult r in report.results)
          <String, Object?>{
            'caseId': r.caseId,
            'passed': r.passed,
            'actualTools': r.actualTools,
            'actualOutput': r.actualOutput,
            'rounds': r.rounds,
          },
      ],
      'passedCount': report.passedCount,
      'passRate': report.passRate,
      'averageRounds': report.averageRounds,
      'diffText': report.compareTo(baseline).toString(),
    },
  };
}

// ═══════════════════════ v1.2 增补：执行安全组 ═══════════════════════

/// approval-flow：拦截矩阵（高风险拦截 / 中风险放行 / pathParams 低风险拦截 /
/// preapproved 放行 / AskUser 通过·拒绝）。
Future<Map<String, Object?>> _approvalFlow() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  // 场景一：默认拒绝，高风险工具被拦截。
  {
    final Context ctx = Context.root();
    final AutoApproval gate = AutoApproval(false);
    final ToolRegistry tools = ToolRegistry()
      ..register(_GatedTool('delete', ToolRisk.high))
      ..register(_GatedTool('echo', ToolRisk.medium));
    provideTools(ctx, tools: tools);
    provideApproval(ctx, approval: gate);
    final ToolResult denied = await tools.call(ToolCall(name: 'delete'));
    final ToolResult passed = await tools.call(ToolCall(name: 'echo'));
    cases.add(<String, Object?>{
      'label': '高拦截中放行（默认拒绝）',
      'expect': <String, Object?>{
        'deniedFailed': denied.isError,
        'deniedCode': denied.error?.code,
        'requests': gate.requests,
        'passedFailed': passed.isError,
      },
    });
    ctx.dispose();
  }

  // 场景二：pathParams 低风险工具被拦截；preapproved 放行不产生请求。
  {
    final Context ctx = Context.root();
    final _PreapproveAll gate = _PreapproveAll();
    final ToolRegistry tools = ToolRegistry()
      ..register(_GatedTool('read_file', ToolRisk.low, pathParams: <String>['path']));
    provideTools(ctx, tools: tools);
    provideApproval(ctx, approval: gate);
    final ToolResult result = await tools.call(
        ToolCall(name: 'read_file', arguments: <String, Object?>{'path': '/etc/hosts'}));
    cases.add(<String, Object?>{
      'label': 'pathParams 低风险工具 preapproved 放行',
      'expect': <String, Object?>{
        'failed': result.isError,
        'requests': gate.requests,
      },
    });
    ctx.dispose();
  }

  // 场景三：AskUser 通过与拒绝。
  {
    final Context ctx = Context.root();
    final CliAskUser ask = CliAskUser();
    final AskUserApproval gate =
        AskUserApproval(askUser: ask, timeout: const Duration(seconds: 5));
    final ToolRegistry tools = ToolRegistry()..register(_GatedTool('delete', ToolRisk.high));
    provideTools(ctx, tools: tools);
    provideApproval(ctx, approval: gate);
    final Future<ToolResult> approvedFuture = tools.call(ToolCall(name: 'delete'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ask.submit('y');
    final ToolResult approved = await approvedFuture;
    final Future<ToolResult> deniedFuture = tools.call(ToolCall(name: 'delete'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ask.submit('n');
    final ToolResult denied = await deniedFuture;
    cases.add(<String, Object?>{
      'label': 'AskUser 通过/拒绝',
      'expect': <String, Object?>{
        'approvedFailed': approved.isError,
        'deniedFailed': denied.isError,
        'deniedCode': denied.error?.code,
      },
    });
    ctx.dispose();
  }

  return <String, Object?>{
    'name': 'approval-flow',
    'kind': 'approval-flow',
    'cases': cases,
  };
}

/// sub-agent：spawn_agent 委托端到端（子模型先调工具再收口）。
Future<Map<String, Object?>> _subAgent() async {
  final Context ctx = Context.root();
  final Session session = Session(id: 'main');
  final _ScriptedProvider scripted = _ScriptedProvider(<LlmResult>[
    LlmResult(content: '', provider: 'scripted', model: 'm', toolCalls: <LlmToolCall>[
      LlmToolCall(id: 'c0', name: 'spawn_agent',
          arguments: '{"task":"现在几点","tools":["get_time"]}'),
    ]),
    LlmResult(content: '', provider: 'scripted', model: 'm', toolCalls: <LlmToolCall>[
      LlmToolCall(id: 'c1', name: 'get_time'),
    ]),
    _text('12:00'),
    _text('子任务完成：12:00'),
  ]);
  final ToolRegistry tools = ToolRegistry();
  tools.register(_TimeTool());
  tools.register(SpawnAgentTool(host: ctx, llm: scripted, tools: tools,
      defaultTools: <String>['get_time']));
  final AgentLoop loop = AgentLoop(llm: scripted, tools: tools, session: session);
  final AgentTurn turn = await loop.run('现在几点');
  final Map<String, Object?> result = <String, Object?>{
    'name': 'sub-agent',
    'kind': 'sub-agent',
    'expect': <String, Object?>{
      'reply': turn.reply,
      'steps': turn.steps.length,
      'stepTool': turn.steps.isEmpty ? null : turn.steps.first.call.name,
      'mainEventTypes': <String>[for (final SessionEvent e in session.events) e.type],
      'mainModelCalls': scripted.calls.length,
    },
  };
  ctx.dispose();
  return result;
}

/// recovery：快照 → 还原 → list/delete → 版本不符抛错。
Future<Map<String, Object?>> _recovery() async {
  final MemorySnapshotStore store = MemorySnapshotStore();
  final RecoveryService recovery = RecoveryService(store: store);
  final Session session = Session(id: 's1');
  session.append(kUserMessageEvent, data: <String, Object?>{'text': '你好'});
  session.append(kAssistantMessageEvent, data: <String, Object?>{'text': '在的'});
  await recovery.snapshot(session);
  final Session restored = await recovery.restore('s1');
  final List<String> listed = await recovery.list();
  await recovery.delete('s1');
  final List<String> afterDelete = await recovery.list();
  String? versionError;
  try {
    SessionSnapshot.fromJson(<String, Object?>{
      'version': 2,
      'sessionId': 'x',
      'events': <Object?>[],
    });
  } on RecoveryException catch (error) {
    versionError = error.code;
  }
  return <String, Object?>{
    'name': 'recovery',
    'kind': 'recovery',
    'expect': <String, Object?>{
      'restoredTypes': <String>[for (final SessionEvent e in restored.events) e.type],
      'restoredSeqs': <int>[for (final SessionEvent e in restored.events) e.seq],
      'listed': listed,
      'afterDelete': afterDelete,
      'versionErrorCode': versionError,
    },
  };
}

/// 固定风险级与路径参数的工具（v1.2；v1.0 的 _FixedTool 无路径参数）。
class _GatedTool extends Tool {
  _GatedTool(this.toolName, this.risk, {this.pathParams = const <String>[]});

  final String toolName;
  final ToolRisk risk;
  final List<String> pathParams;

  @override
  String get name => toolName;
  @override
  String get description => toolName;
  @override
  ToolRisk get riskLevel => risk;
  @override
  Future<ToolResult> call(ToolContext ctx) async => ToolResult.success('ok');
}

/// preapproved 恒放行的审批。
class _PreapproveAll extends Approval {
  int requests = 0;

  @override
  Stream<ApprovalRequest> get pending => const Stream<ApprovalRequest>.empty();

  @override
  Future<bool> preapproved(ApprovalRequest request) async => true;

  @override
  Future<bool> request(ApprovalRequest request) async {
    requests++;
    return false;
  }
}

// ═══════════════════════ v1.3 增补：skill 沉淀 ═══════════════════════

/// skill：命名规范化 / 元信息解析 / 占位符注入 / 提取沉淀与审批/安全边界 /
/// 记忆持久化恢复。
Future<Map<String, Object?>> _skill() async {
  final List<Map<String, Object?>> nameCases = <Map<String, Object?>>[
    <String, Object?>{
      'input': 'Foo Bar!',
      'expect': skillNameFrom('Foo Bar!'),
    },
    <String, Object?>{
      'input': '___',
      'expect': skillNameFrom('___'),
    },
    <String, Object?>{
      'input': ' 你好 World ',
      'expect': skillNameFrom(' 你好 World '),
    },
  ];

  final List<Map<String, Object?>> metaCases = <Map<String, Object?>>[
    <String, Object?>{
      'label': 'JSON 命中',
      'input': '{"name":"SearchWeb","description":"搜索网络"}',
      'tools': <String>['search'],
      'expect': await _metaJson(parseSkillMeta('{"name":"SearchWeb","description":"搜索网络"}', <String>['search'])),
    },
    <String, Object?>{
      'label': 'name 缺失回退确定性',
      'input': '只有描述',
      'tools': <String>['a', 'b'],
      'expect': await _metaJson(parseSkillMeta('只有描述', <String>['a', 'b'])),
    },
  ];

  // 占位符注入端到端。
  final ToolRegistry placeholderTools = ToolRegistry()..register(_EchoTool());
  final SkillTool skill = SkillTool(
    name: 'greet',
    description: '问候',
    steps: <SkillStep>[
      SkillStep(toolName: 'echo', arguments: <String, Object?>{'text': '你好 {{name}}！'}),
      SkillStep(toolName: 'echo', arguments: <String, Object?>{'text': '再见 {{name}}'}),
    ],
    tools: placeholderTools,
  );
  final ToolResult skillResult = await skill.call(ToolContext(ToolCall(
    name: 'greet',
    arguments: <String, Object?>{'name': '小明'},
  )));

  // 提取沉淀：同序列 3 次 → 注册；high 风险不沉淀；审批拒绝不沉淀。
  final SkillLibrary library = SkillLibrary(threshold: 3);
  for (int i = 0; i < 3; i++) {
    library.recordTools('任务$i', <String>['echo']);
  }
  final ToolRegistry extractTools = ToolRegistry()..register(_EchoTool());
  final SkillTool? extracted = await library.maybeExtract(tools: extractTools);

  final SkillLibrary safeLibrary = SkillLibrary(threshold: 1);
  safeLibrary.recordTools('高危', <String>['risky']);
  final ToolRegistry safeTools = ToolRegistry()
    ..register(_EchoTool())
    ..register(_GatedTool('risky', ToolRisk.high));
  final SkillTool? notExtracted = await safeLibrary.maybeExtract(tools: safeTools);

  final SkillLibrary deniedLibrary = SkillLibrary(threshold: 1, approval: AutoApproval(false));
  deniedLibrary.recordTools('审批拒绝', <String>['echo']);
  final ToolRegistry deniedTools = ToolRegistry()..register(_EchoTool());
  final SkillTool? denied = await deniedLibrary.maybeExtract(tools: deniedTools);

  // 记忆持久化 + 恢复。
  final MemoryStore memory = MemoryStore();
  final SkillLibrary persistedLibrary = SkillLibrary(threshold: 1, memory: memory);
  persistedLibrary.recordTools('记忆', <String>['echo']);
  final ToolRegistry persistTools = ToolRegistry()..register(_EchoTool());
  await persistedLibrary.maybeExtract(tools: persistTools);
  final ToolRegistry freshTools = ToolRegistry()..register(_EchoTool());
  final int restored = await persistedLibrary.restore(tools: freshTools);

  return <String, Object?>{
    'name': 'skill',
    'kind': 'skill',
    'nameCases': nameCases,
    'metaCases': metaCases,
    'expect': <String, Object?>{
      'skillParams': <String>[for (final ParamSpec p in skill.params) p.name],
      'skillResultContent': skillResult.content,
      'skillResultValue': skillResult.value,
      'extractedName': extracted?.name,
      'extractedRegistered': extractTools.get(extracted?.name ?? '') != null,
      'highRiskNotExtracted': notExtracted == null,
      'deniedNotExtracted': denied == null,
      'restored': restored,
      'restoredRegistered': freshTools.get('skill_echo') != null,
    },
  };
}

/// 回显工具。
class _EchoTool extends Tool {
  @override
  String get name => 'echo';
  @override
  String get description => '回显';
  @override
  Future<ToolResult> call(ToolContext ctx) async {
    final String text = '${ctx.arguments['text'] ?? ''}';
    return ToolResult.success(text, value: text);
  }
}


Map<String, Object?> _metaJson(SkillMeta meta) =>
    <String, Object?>{'name': meta.name, 'description': meta.description};

// ═══════════════════════ v1.4 增补：goal ═══════════════════════

/// goal-flow：状态机 / 重复创建 / cleared 还原 / fork 不继承 / 工具端到端 /
/// approval 拒绝 / 续行驱动器。
Future<Map<String, Object?>> _goalFlow() async {
  final Session session = Session(id: 's1');
  final DefaultGoalService goal = DefaultGoalService(session: session, defaultMaxRounds: 3);
  final Goal created = await goal.create('学英语');
  final Goal edited = await goal.edit('学英语每天');
  final Goal paused = await goal.pause();
  final Goal resumed = await goal.resume();
  await goal.advanceRound();
  await goal.advanceRound();
  await goal.advanceRound();
  final Goal finalState = goal.current!;
  String? duplicateCode;
  try {
    await goal.create('另一个');
  } on GoalException catch (e) {
    duplicateCode = e.code;
  }

  final Session clearedSession = Session(id: 's2');
  final DefaultGoalService clearedService = DefaultGoalService(session: clearedSession);
  await clearedService.create('临时目标');
  await clearedService.clear();
  final Goal? clearedRestored = restoreGoalState(clearedSession);

  final Session forkSession = Session(id: 's3');
  final DefaultGoalService forkGoal = DefaultGoalService(session: forkSession);
  await forkGoal.create('父目标');
  final Session forked = forkSession.fork(id: 's3-fork-1');
  final Goal? forkRestored = restoreGoalState(forked);

  final Context ctx = Context.root();
  final ToolRegistry tools = ToolRegistry();
  provideTools(ctx, tools: tools);
  final DefaultGoalService toolGoal = DefaultGoalService(session: Session(id: 's4'));
  provideGoal(ctx, goal: toolGoal, tools: tools);
  final ToolResult toolReply = await tools.call(ToolCall(name: 'create_goal', arguments: <String, Object?>{'text': '报时'}));

  String? approvalDeniedCode;
  final DefaultGoalService deniedGoal = DefaultGoalService(
    session: Session(id: 's5'),
    approval: AutoApproval(false),
  );
  await deniedGoal.create('需确认');
  try {
    await deniedGoal.complete();
  } on GoalException catch (e) {
    approvalDeniedCode = e.code;
  }

  final Session driverSession = Session(id: 's6');
  final DefaultGoalService driverGoal = DefaultGoalService(session: driverSession, defaultMaxRounds: 2);
  await driverGoal.create('驱动目标');
  final _ScriptedProvider driverLlm = _ScriptedProvider(<LlmResult>[_text('回复1'), _text('回复2')]);
  final AgentLoop driverLoop = AgentLoop(llm: driverLlm, tools: ToolRegistry(), session: driverSession);
  final GoalRoundDriver driver = GoalRoundDriver(goal: driverGoal, agent: driverLoop);
  driverLoop.goalDriver = driver;
  final AgentTurn driverTurn = await driverLoop.run('开始');
  final Goal driverFinal = driverGoal.current!;

  return <String, Object?>{
    'name': 'goal-flow',
    'kind': 'goal-flow',
    'expect': <String, Object?>{
      'createdStatus': created.status.name,
      'editedText': edited.text,
      'pausedStatus': paused.status.name,
      'resumedStatus': resumed.status.name,
      'finalRound': finalState.round,
      'finalBlocked': finalState.status == GoalStatus.blocked,
      'finalBlockReason': finalState.blockReason,
      'sessionEventTypes': <String>[for (final SessionEvent e in session.events) e.type],
      'duplicateCode': duplicateCode,
      'clearedRestored': clearedRestored == null,
      'forkNotInherited': forkRestored == null,
      'toolReply': toolReply.content,
      'approvalDeniedCode': approvalDeniedCode,
      'driverReply': driverTurn.reply,
      'driverRound': driverFinal.round,
      'driverBlocked': driverFinal.status == GoalStatus.blocked,
      'driverModelCalls': driverLlm.calls.length,
    },
  };
}

// ═══════════════════════ v1.5 增补：autonomous ═══════════════════════

/// autonomous-flow：TimeWindow / PriorityEngine / Runner 停止矩阵（正常完成 /
/// 预算超限 / 轮次上限 / 运行前停止）。
Future<Map<String, Object?>> _autonomousFlow() async {
  final List<Map<String, Object?>> windowCases = <Map<String, Object?>>[];
  final TimeWindow day = TimeWindow(start: const Duration(hours: 9), end: const Duration(hours: 17));
  final TimeWindow night = TimeWindow(start: const Duration(hours: 22), end: const Duration(hours: 6));
  windowCases.add(<String, Object?>{
    'label': '端点含（09:00 与 17:00 在窗口内）',
    'expect': <String, Object?>{
      'at9': day.contains(DateTime(2026, 8, 6, 9, 0)),
      'at17': day.contains(DateTime(2026, 8, 6, 17, 0)),
      'at8': day.contains(DateTime(2026, 8, 6, 8, 59)),
    },
  });
  windowCases.add(<String, Object?>{
    'label': '跨午夜窗口与 nextStart',
    'expect': <String, Object?>{
      'at23': night.contains(DateTime(2026, 8, 6, 23, 30)),
      'at1': night.contains(DateTime(2026, 8, 6, 1, 0)),
      'at12': night.contains(DateTime(2026, 8, 6, 12, 0)),
      'nextFrom10': night.nextStart(DateTime(2026, 8, 6, 10, 0)).hour,
      'nextFrom23': night.nextStart(DateTime(2026, 8, 6, 23, 0)).day,
    },
  });

  final List<Map<String, Object?>> priorityCases = <Map<String, Object?>>[];
  final PriorityEngine engine = PriorityEngine();
  final Goal low = Goal(id: 'a', text: '低', status: GoalStatus.active, round: 0, maxRounds: 10, createdAt: DateTime(2026), updatedAt: DateTime(2026));
  final Goal high = Goal(id: 'b', text: '高', status: GoalStatus.active, round: 9, maxRounds: 10, createdAt: DateTime(2026), updatedAt: DateTime(2026));
  priorityCases.add(<String, Object?>{
    'label': '默认重要性下 urgency 生效',
    'expect': <String, Object?>{
      'scoreA': engine.scoreOf(low).score,
      'scoreB': engine.scoreOf(high).score,
      'selected': engine.selectNext(<Goal>[low, high])?.id,
    },
  });
  priorityCases.add(<String, Object?>{
    'label': 'importance 覆盖',
    'expect': <String, Object?>{
      'selected': engine.selectNext(<Goal>[low, high], importance: <String, int>{'a': 10})?.id,
    },
  });

  // Runner 停止矩阵（注入固定时钟 2026-08-06 12:00）。
  final DateTime fixedNow = DateTime(2026, 8, 6, 12);
  DateTime Function() clock() => () => fixedNow;

  final List<Map<String, Object?>> runnerCases = <Map<String, Object?>>[];

  // 正常完成：maxRounds 2 → 2 轮后 advanceRound 达上限自动 block → humanRequired。
  {
    final Session session = Session(id: 'r1');
    final DefaultGoalService goal = DefaultGoalService(session: session, defaultMaxRounds: 2);
    await goal.create('自主目标');
    final _ScriptedProvider llm = _ScriptedProvider(<LlmResult>[_text('回复1'), _text('回复2')]);
    final AgentLoop agent = AgentLoop(llm: llm, tools: ToolRegistry(), session: session);
    final DefaultAutonomousRunner runner = DefaultAutonomousRunner(
      agent: agent,
      goal: goal,
      session: session,
      policy: const DefaultAutonomousPolicy(),
      clock: clock());
    final AutonomousResult result = await runner.run();
    runnerCases.add(<String, Object?>{
      'label': '正常完成（达轮次上限自动阻塞）',
      'expect': <String, Object?>{
        'stoppedReason': result.stoppedReason.name,
        'turns': result.turns.length,
        'replies': <String>[for (final AgentTurn t in result.turns) t.reply],
        'advanced': result.goalsAdvanced.length,
      },
    });
  }

  // 预算超限：todayCost 10 > dailyBudget 5 → 0 轮。
  {
    final Session session = Session(id: 'r2');
    final DefaultGoalService goal = DefaultGoalService(session: session);
    await goal.create('自主目标');
    final _ScriptedProvider llm = _ScriptedProvider(<LlmResult>[_text('不该出现')]);
    final AgentLoop agent = AgentLoop(llm: llm, tools: ToolRegistry(), session: session);
    final DefaultAutonomousRunner runner = DefaultAutonomousRunner(
      agent: agent,
      goal: goal,
      session: session,
      policy: const DefaultAutonomousPolicy(dailyBudget: 5),
      costTracker: _FixedCostTracker(10),
      clock: clock(),
    );
    final AutonomousResult result = await runner.run();
    runnerCases.add(<String, Object?>{
      'label': '预算超限',
      'expect': <String, Object?>{
        'stoppedReason': result.stoppedReason.name,
        'turns': result.turns.length,
      },
    });
  }

  // 轮次上限：maxContinuousRounds 2 → 2 轮后 maxRoundsReached。
  {
    final Session session = Session(id: 'r3');
    final DefaultGoalService goal = DefaultGoalService(session: session, defaultMaxRounds: 100);
    await goal.create('自主目标');
    final _ScriptedProvider llm = _ScriptedProvider(
        <LlmResult>[_text('回复1'), _text('回复2'), _text('回复3')]);
    final AgentLoop agent = AgentLoop(llm: llm, tools: ToolRegistry(), session: session);
    final DefaultAutonomousRunner runner = DefaultAutonomousRunner(
      agent: agent,
      goal: goal,
      session: session,
      policy: const DefaultAutonomousPolicy(maxContinuousRounds: 2),
      clock: clock(),
    );
    final AutonomousResult result = await runner.run();
    runnerCases.add(<String, Object?>{
      'label': '达到轮次上限',
      'expect': <String, Object?>{
        'stoppedReason': result.stoppedReason.name,
        'turns': result.turns.length,
      },
    });
  }

  // 运行前停止：stop() 取消当次 → 0 轮 manualStop。
  {
    final Session session = Session(id: 'r4');
    final DefaultGoalService goal = DefaultGoalService(session: session);
    await goal.create('自主目标');
    final _ScriptedProvider llm = _ScriptedProvider(<LlmResult>[_text('不该出现')]);
    final AgentLoop agent = AgentLoop(llm: llm, tools: ToolRegistry(), session: session);
    final DefaultAutonomousRunner runner = DefaultAutonomousRunner(
      agent: agent,
      goal: goal,
      session: session,
      policy: const DefaultAutonomousPolicy(),
      clock: clock());
    runner.stop();
    final AutonomousResult result = await runner.run();
    runnerCases.add(<String, Object?>{
      'label': '运行前停止',
      'expect': <String, Object?>{
        'stoppedReason': result.stoppedReason.name,
        'turns': result.turns.length,
      },
    });
  }

  return <String, Object?>{
    'name': 'autonomous-flow',
    'kind': 'autonomous-flow',
    'windowCases': windowCases,
    'priorityCases': priorityCases,
    'runnerCases': runnerCases,
  };
}

/// 固定成本追踪器。
class _FixedCostTracker implements CostTracker {
  _FixedCostTracker(this.todayCost);
  @override
  final double todayCost;
}

// ═══════════════════════ v1.6 增补：plan-mode + prompt-evolver ═══════════════════════

/// plan-mode-flow：enter/exit/拦截/exit_plan_mode 工具/restore。
Future<Map<String, Object?>> _planModeFlow() async {
  final Session session = Session(id: 'p1');
  final SystemPrompt prompt = SystemPrompt()
    ..section(PromptSection(name: 'persona', text: () => '你是助手。'));
  final AutoApproval approval = AutoApproval(true);
  final DefaultPlanMode planMode = DefaultPlanMode(
    session: session, prompt: prompt, approval: approval);
  final ToolRegistry tools = ToolRegistry()
    ..register(_GatedTool('read', ToolRisk.low))
    ..register(_GatedTool('write', ToolRisk.medium));
  planMode.enter();
  final ToolResult lowOk = await tools.call(ToolCall(name: 'read'));
  // 拦截由 providePlanMode 的中间件实现——此处直接用服务 + 手挂拦截？导出器里
  // 用 providePlanMode 装好（含拦截中间件），再测调用。
  final Context ctx = Context.root();
  provideTools(ctx, tools: tools);
  providePlanMode(ctx, planMode: planMode, tools: tools, prompt: prompt, approval: approval);
  final ToolResult blocked = await tools.call(ToolCall(name: 'write'));
  // 激活期间快照 policy 段（exit 前）。
  final List<String> assembledActive = <String>[
    for (final AssembledSection s in prompt.assemble().sections) s.name,
  ];
  final ToolResult exitOk = await tools.call(ToolCall(name: kExitPlanModeToolName,
      arguments: <String, Object?>{'goal': '改文档', 'steps': <Object?>['读', '写']}));
  final List<String> events = <String>[for (final SessionEvent e in session.events) e.type];

  // restore：新实例从会话还原 active。
  final DefaultPlanMode restored = DefaultPlanMode(session: Session(id: 'p2')..append(kPlanModeEvent, data: <String, Object?>{'state': 'active'}));
  // p2 的事件构造：直接 append。

  return <String, Object?>{
    'name': 'plan-mode-flow',
    'kind': 'plan-mode-flow',
    'expect': <String, Object?>{
      'policyInjected': assembledActive.contains('plan:policy'),
      'lowOkFailed': lowOk.isError,
      'blockedFailed': blocked.isError,
      'blockedCode': blocked.error?.code,
      'exitReply': exitOk.content,
      'stateAfterExit': planMode.state.name,
      'sessionEvents': events,
    },
  };
}

/// prompt-evolver-flow：propose 阈值 / evaluate A/B / promote 阈值不足 / rollback 缺失。
Future<Map<String, Object?>> _promptEvolverFlow() async {
  final SystemPrompt prompt = SystemPrompt()
    ..section(PromptSection(name: 'persona', text: () => '你是助手。'));
  final _ScriptedProvider llm = _ScriptedProvider(<LlmResult>[
    _text('失败模式：指令不够具体'),
    _text('改进后的 persona：更具体地要求工具。'),
  ]);
  final _ScriptedProvider evalLlm = _ScriptedProvider(<LlmResult>[_text('回答')]);
  final ToolRegistry evalTools = ToolRegistry()..register(_TimeTool());
  final AgentLoop evalAgent = AgentLoop(llm: evalLlm, tools: evalTools);
  final Evaluator evaluator = Evaluator(run: (String input) => evalAgent.run(input));
  final DefaultPromptEvolver evolver = DefaultPromptEvolver(
    llm: llm,
    evaluator: evaluator,
    prompt: prompt,
    evalCases: <EvalCase>[
      const EvalCase(id: 'a', input: '现在几点', expectedOutput: '回答'),
    ],
    minTraces: 3,
  );

  final SessionEvent fakeTrace = SessionEvent.create(
      sessionId: 's', type: kToolResultEvent, seq: 0,
      data: <String, Object?>{'name': 'get_time', 'content': '错误'});
  final PromptVariant? insufficient =
      await evolver.propose(sectionName: 'persona', lowQualityTraces: <SessionEvent>[]);
  final PromptVariant? proposed = await evolver.propose(
      sectionName: 'persona', lowQualityTraces: <SessionEvent>[fakeTrace, fakeTrace, fakeTrace]);
  final EvolutionResult evaluated = await evolver.evaluate(proposed!);
  final bool promoted = await evolver.promote(proposed, threshold: 0.05);
  String? rollbackError;
  try {
    await evolver.rollback('ghost');
  } on StateError catch (e) {
    rollbackError = e.message;
  }

  return <String, Object?>{
    'name': 'prompt-evolver-flow',
    'kind': 'prompt-evolver-flow',
    'expect': <String, Object?>{
      'insufficientNull': insufficient == null,
      'proposedSection': proposed.sectionName,
      'proposedParentNull': proposed.parentId == null,
      'evaluatedDecision': evaluated.decision.name,
      'evaluatedImprovement': evaluated.improvement,
      'promoted': promoted,
      'rollbackErrorContains': rollbackError != null && rollbackError.contains('ghost'),
    },
  };
}
