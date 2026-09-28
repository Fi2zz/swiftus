// S17 任务中心 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 本文件的 fixture 统一形状：{name, kind, cases:[...]}；kind 分派见各 _fixture 函数。
//
// 归一化（S17 专用）：
// - 任务 id 按首次出现顺序替换为 `<task-1>` / `<task-2>` …（Dart id 内嵌墙钟微秒）；
// - createdAt / startedAt / finishedAt 不入投影，改为 hasStartedAt / hasFinishedAt 布尔
//   （createdAt 恒有），只在本文件内用于计算 duration 的用例里以 ISO 串出现。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conatus_agent/conatus_agent.dart';
import 'package:conatus_core/conatus_core.dart';
import 'package:conatus_foundation/conatus_foundation.dart';
import 'package:conatus_llm/conatus_llm.dart';
import 'package:conatus_schedule/conatus_schedule.dart';
import 'package:conatus_tasks/conatus_tasks.dart';

/// id 归一化表：原始 id → `<task-N>`（按首次出现顺序）。
class _Ids {
  final Map<String, String> mapping = <String, String>{};

  String call(String raw) =>
      mapping.putIfAbsent(raw, () => '<task-${mapping.length + 1}>');
}

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, FutureOr<Map<String, Object?>> Function()> fixtures =
      <String, FutureOr<Map<String, Object?>> Function()>{
    'task-json': _taskJson,
    'state-machine': () async => _stateMachine(),
    'task-tree': () async => _taskTree(),
    'restore': _restore,
    'task-tools': () async => _taskTools(),
    'tracking-flow': _trackingFlow,
  };
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, FutureOr<Map<String, Object?>> Function()> entry
      in fixtures.entries) {
    final Map<String, Object?> fixture = await Future<Map<String, Object?>>.sync(
      entry.value,
    );
    File('${outDir.path}/${entry.key}.json')
        .writeAsStringSync('${encoder.convert(fixture)}\n');
    stdout.writeln('导出 ${entry.key}.json');
  }
}

Directory _outputDir() {
  final Directory here = File.fromUri(Platform.script).parent;
  return Directory('${here.parent.parent.path}/spec/fixtures/s17');
}

// ───────────────────────────── 投影 ─────────────────────────────

/// 任务投影：id 归一化、时刻折叠为布尔标记（createdAt 恒有故不入投影）。
///
/// result 只在 JSON 形态可比时入投影（不可编码值退化为字符串，那一步是语言相关的
/// 展示面）；error 只投影**形态**（失败原因的语言相关文本不入 fixture），且形态只
/// 从**持久化后**的载荷取——内存态错误值的形态随语言类型系统而异（持久化前可能是
/// 对象、也可能是字符串），内容断言由各用例的显式布尔承担。
Map<String, Object?> _task(Task task, _Ids ids, {bool persisted = false}) =>
    <String, Object?>{
      'id': ids(task.id),
      'kind': task.kind.name,
      'status': task.status.name,
      'description': task.description,
      'hasStartedAt': task.startedAt != null,
      'hasFinishedAt': task.finishedAt != null,
      'parentTaskId':
          task.parentTaskId == null ? null : ids(task.parentTaskId!),
      'metadata': task.metadata,
      'hasResult': task.result != null,
      'hasError': task.error != null,
      'result': _valueJson(task.result),
      if (persisted) 'errorShape': _valueShape(task.error),
    };

/// 值的 JSON 形态名（无值时为 none）。
String _valueShape(Object? value) {
  if (value == null) return 'none';
  if (value is String) return 'string';
  if (value is num) return 'number';
  if (value is bool) return 'bool';
  if (value is List) return 'array';
  if (value is Map) return 'object';
  return 'other';
}

/// 保留 JSON 结构；不可编码的值按 null 出（退化标记由 has* 布尔承担）。
Object? _valueJson(Object? value) {
  if (value == null) return null;
  try {
    return jsonDecode(jsonEncode(value));
  } catch (_) {
    return null;
  }
}

List<Object?> _tasks(List<Task> tasks, _Ids ids) =>
    <Object?>[for (final Task task in tasks) _task(task, ids)];

/// 会话日志投影：事件类型 + 归一化后的 task/changed 载荷（错误形态取持久化值）。
List<Object?> _log(Session session, _Ids ids) => <Object?>[
      for (final SessionEvent event in session.ownEvents)
        <String, Object?>{
          'type': event.type,
          'task': event.type == kTaskEvent
              ? _task(
                  Task.fromJson(Map<String, Object?>.from(event.data! as Map)),
                  ids,
                  persisted: true,
                )
              : null,
        },
    ];

List<String> _telemetry(InMemoryTelemetry telemetry) =>
    <String>[for (final TelemetryEvent event in telemetry.recent) event.name];

/// 带会话与埋点的任务中心。
class _Harness {
  _Harness({Approval? approval}) {
    center = DefaultTaskCenter(
      session: session,
      approval: approval,
      telemetry: telemetry,
    );
  }

  final Session session = Session(id: 's1');
  final InMemoryTelemetry telemetry = InMemoryTelemetry();
  late final DefaultTaskCenter center;
  final _Ids ids = _Ids();
}

String _errorCode(Object error) =>
    error is TaskException ? error.code : error.runtimeType.toString();

/// 记录式审批替身：捕获任务中心发出的取消确认请求（AutoApproval 只计数）。
class _RecordingApproval extends Approval {
  _RecordingApproval(this.approved);

  final bool approved;
  final List<ApprovalRequest> requests = <ApprovalRequest>[];

  @override
  Future<bool> request(ApprovalRequest request) async {
    requests.add(request);
    return approved;
  }

  @override
  Stream<ApprovalRequest> get pending => const Stream<ApprovalRequest>.empty();
}

// ───────────────────────────── 词汇与 JSON ─────────────────────────────

/// kind = task-json：状态谓词矩阵 / copyWith 语义 / JSON 往返 / 宽容解析。
Map<String, Object?> _taskJson() {
  final DateTime created = DateTime.parse('2026-09-17T10:00:00.123Z');
  return <String, Object?>{
    'name': 'task-json',
    'kind': 'task-json',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'status-matrix',
        'label': '终态与活跃矩阵',
        'cases': <Object?>[
          for (final TaskStatus status in TaskStatus.values)
            <String, Object?>{
              'status': status.name,
              'isTerminal': _sample(status: status).isTerminal,
              'isActive': _sample(status: status).isActive,
            },
        ],
      },
      <String, Object?>{
        'scenario': 'copy-with',
        'label': 'copyWith 未传参保持原值、传 null 清除可空字段',
        'expect': _copyWithCase(),
      },
      <String, Object?>{
        'scenario': 'round-trip',
        'label': 'toJson / fromJson 往返一致',
        'input': _roundTripTask().toJson(),
        'expect': _roundTripCase(),
      },
      <String, Object?>{
        'scenario': 'tolerant-enums',
        'label': '宽容解析：未知枚举回退',
        'input': <String, Object?>{
          'id': 'x',
          'kind': 'nonsense',
          'status': 'weird',
          'description': 'd',
          'createdAt': '2026-09-17T10:00:00.000Z',
        },
        'expect': _tolerant(<String, Object?>{
          'id': 'x',
          'kind': 'nonsense',
          'status': 'weird',
          'description': 'd',
          'createdAt': '2026-09-17T10:00:00.000Z',
        }),
      },
      <String, Object?>{
        'scenario': 'tolerant-instants',
        'label': '宽容解析：非法可选时刻按 nil，metadata 保留键值',
        'input': <String, Object?>{
          'id': 'y',
          'kind': 'shell',
          'status': 'running',
          'description': 'sleep 100',
          'createdAt': '2026-09-17T10:00:00.000Z',
          'startedAt': 'not-a-date',
          'finishedAt': 'nope',
          'metadata': <String, Object?>{'command': 'sleep 100'},
        },
        'expect': _tolerant(<String, Object?>{
          'id': 'y',
          'kind': 'shell',
          'status': 'running',
          'description': 'sleep 100',
          'createdAt': '2026-09-17T10:00:00.000Z',
          'startedAt': 'not-a-date',
          'finishedAt': 'nope',
          'metadata': <String, Object?>{'command': 'sleep 100'},
        }),
      },
    ],
  };
}

Task _sample({TaskStatus status = TaskStatus.pending}) => Task(
      id: 't1',
      kind: TaskKind.custom,
      status: status,
      description: '查机票',
      createdAt: DateTime(2026, 9, 17, 10),
    );

Map<String, Object?> _copyWithCase() {
  final Task task = _sample(status: TaskStatus.running).copyWith(
    startedAt: DateTime(2026, 9, 17, 10),
    result: 'ok',
    error: 'oops',
  );
  final Task untouched = task.copyWith();
  final Task cleared = task.copyWith(result: null, error: null);
  return <String, Object?>{
    'keptResult': untouched.result,
    'keptError': untouched.error,
    'keptStartedAt': untouched.startedAt != null,
    'clearedResult': cleared.result,
    'clearedError': cleared.error,
    'originalResult': task.result,
    'originalError': task.error,
  };
}

Task _roundTripTask() => Task(
      id: 't9',
      kind: TaskKind.subAgent,
      status: TaskStatus.failed,
      description: '子 Agent: 查机票',
      createdAt: DateTime.parse('2026-09-17T10:00:00.123Z'),
      startedAt: DateTime.parse('2026-09-17T10:01:00.000Z'),
      finishedAt: DateTime.parse('2026-09-17T10:02:00.000Z'),
      parentTaskId: 'parent-1',
      metadata: <String, Object?>{'goalId': 'g1', 'maxRounds': 3},
      result: <String, Object?>{'exitCode': 0},
      error: '超时',
    );

Map<String, Object?> _roundTripCase() {
  final Task task = _roundTripTask();
  final Task restored = Task.fromJson(task.toJson());
  return <String, Object?>{
    'id': restored.id,
    'kind': restored.kind.name,
    'status': restored.status.name,
    'description': restored.description,
    'createdAt': restored.createdAt.toIso8601String(),
    'startedAt': restored.startedAt!.toIso8601String(),
    'finishedAt': restored.finishedAt!.toIso8601String(),
    'parentTaskId': restored.parentTaskId,
    'metadata': restored.metadata,
    'result': restored.result,
    'error': restored.error,
    'durationInSeconds': restored.duration!.inSeconds,
    'isTerminal': restored.isTerminal,
  };
}

Map<String, Object?> _tolerant(Map<String, Object?> json) {
  final Task task = Task.fromJson(json);
  return <String, Object?>{
    'id': task.id,
    'kind': task.kind.name,
    'status': task.status.name,
    'description': task.description,
    'hasStartedAt': task.startedAt != null,
    'hasFinishedAt': task.finishedAt != null,
    'metadata': task.metadata,
  };
}

// ───────────────────────────── 状态机 ─────────────────────────────

/// kind = state-machine：create / update 的落盘、埋点与错误码。
Future<Map<String, Object?>> _stateMachine() async {
  return <String, Object?>{
    'name': 'state-machine',
    'kind': 'state-machine',
    'cases': <Object?>[
      await _createCase(),
      await _runningCase(),
      await _pauseResumeCase(),
      await _terminalGuardCase(),
      await _noChangeCase(),
      await _disposeCase(),
    ],
  };
}

Future<Map<String, Object?>> _createCase() async {
  final _Harness harness = _Harness();
  final Task task = await harness.center.create(
    kind: TaskKind.custom,
    description: '查机票',
    metadata: <String, Object?>{'goalId': 'g1'},
  );
  return <String, Object?>{
    'scenario': 'create',
    'label': 'create 落 pending 并持久化 task/changed 事件',
    'expect': <String, Object?>{
      'task': _task(task, harness.ids),
      'all': harness.center.all.length,
      'active': harness.center.active.length,
      'log': _log(harness.session, harness.ids),
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

Future<Map<String, Object?>> _runningCase() async {
  final _Harness harness = _Harness();
  final Task created = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  final Task running =
      await harness.center.update(created.id, status: TaskStatus.running);
  final Task done = await harness.center.update(
    created.id,
    status: TaskStatus.completed,
    result: 'ok',
  );
  return <String, Object?>{
    'scenario': 'running',
    'label': 'running 自动 startedAt，completed 自动 finishedAt',
    'expect': <String, Object?>{
      'running': _task(running, harness.ids),
      'done': _task(done, harness.ids),
      'durationInSeconds': done.duration!.inSeconds,
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

Future<Map<String, Object?>> _pauseResumeCase() async {
  final _Harness harness = _Harness();
  final Task created = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  await harness.center.update(created.id, status: TaskStatus.running);
  final Task paused =
      await harness.center.update(created.id, status: TaskStatus.paused);
  final Task resumed =
      await harness.center.update(created.id, status: TaskStatus.running);
  return <String, Object?>{
    'scenario': 'pause-resume',
    'label': '暂停与恢复：埋点 task.paused / task.resumed，startedAt 不被覆盖',
    'expect': <String, Object?>{
      'paused': _task(paused, harness.ids),
      'resumed': _task(resumed, harness.ids),
      'telemetry': _telemetry(harness.telemetry),
      'log': _log(harness.session, harness.ids),
    },
  };
}

Future<Map<String, Object?>> _terminalGuardCase() async {
  final _Harness harness = _Harness();
  final Task created = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  await harness.center.update(created.id, status: TaskStatus.completed);
  final List<String> codes = <String>[];
  try {
    await harness.center.update(created.id, status: TaskStatus.running);
  } catch (error) {
    codes.add(_errorCode(error));
  }
  try {
    await harness.center.update('nope', status: TaskStatus.running);
  } catch (error) {
    codes.add(_errorCode(error));
  }
  return <String, Object?>{
    'scenario': 'terminal-guard',
    'label': '终态任务不可再更新；未知任务抛 not-found',
    'expect': <String, Object?>{'codes': codes},
  };
}

Future<Map<String, Object?>> _noChangeCase() async {
  final _Harness harness = _Harness();
  final Task created = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  await harness.center.update(created.id, status: TaskStatus.pending);
  return <String, Object?>{
    'scenario': 'no-change',
    'label': '无实际变化的 update 不落盘不埋点',
    'expect': <String, Object?>{
      'logCount': harness.session.ownEvents.length,
      'telemetry': _telemetry(harness.telemetry),
      'task': _task(harness.center.get(created.id)!, harness.ids),
    },
  };
}

Future<Map<String, Object?>> _disposeCase() async {
  final _Harness harness = _Harness();
  final Task created = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  await harness.center.update(created.id, status: TaskStatus.running);
  harness.center.dispose();
  harness.center.dispose();
  final List<String> codes = <String>[];
  try {
    await harness.center.create(kind: TaskKind.custom, description: 'y');
  } catch (error) {
    codes.add(_errorCode(error));
  }
  try {
    await harness.center.update(created.id, status: TaskStatus.paused);
  } catch (error) {
    codes.add(_errorCode(error));
  }
  return <String, Object?>{
    'scenario': 'dispose',
    'label': 'dispose 幂等，释放后 create / update 抛 disposed',
    'expect': <String, Object?>{
      'codes': codes,
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

// ───────────────────────────── 任务树与取消 ─────────────────────────────

/// kind = task-tree：childrenOf / subtreeOf 与取消（级联 + 审批 + 回调）。
Future<Map<String, Object?>> _taskTree() async {
  return <String, Object?>{
    'name': 'task-tree',
    'kind': 'task-tree',
    'cases': <Object?>[
      await _treeShapeCase(),
      await _cascadeCancelCase(),
      await _shellApprovalCase(),
      await _nonShellNoApprovalCase(),
      await _cancelTerminalCase(),
    ],
  };
}

Future<Map<String, Object?>> _treeShapeCase() async {
  final _Harness harness = _Harness();
  final Task root = await harness.center.create(
    kind: TaskKind.agentTurn,
    description: 'root',
  );
  final Task childA = await harness.center.create(
    kind: TaskKind.subAgent,
    description: 'a',
    parentTaskId: root.id,
  );
  final Task childB = await harness.center.create(
    kind: TaskKind.shell,
    description: 'b',
    parentTaskId: root.id,
  );
  final Task grandChild = await harness.center.create(
    kind: TaskKind.custom,
    description: 'a1',
    parentTaskId: childA.id,
  );
  // 先按创建顺序登记 id，投影里的 <task-N> 才与遍历顺序无关。
  for (final Task task in <Task>[root, childA, childB, grandChild]) {
    harness.ids(task.id);
  }
  return <String, Object?>{
    'scenario': 'tree-shape',
    'label': 'childrenOf 只取直接子任务，subtreeOf 栈式深度优先含自己',
    'expect': <String, Object?>{
      'childrenOfRoot': _tasks(harness.center.childrenOf(root.id), harness.ids),
      'childrenOfChildA':
          _tasks(harness.center.childrenOf(childA.id), harness.ids),
      'subtreeOfRoot': _tasks(harness.center.subtreeOf(root.id), harness.ids),
      'subtreeOfMissing': harness.center.subtreeOf('ghost').length,
      'ids': <String?>[
        harness.ids(root.id),
        harness.ids(childA.id),
        harness.ids(childB.id),
        harness.ids(grandChild.id),
      ],
    },
  };
}

Future<Map<String, Object?>> _cascadeCancelCase() async {
  final _Harness harness = _Harness();
  final Task root = await harness.center.create(
    kind: TaskKind.agentTurn,
    description: 'root',
  );
  final Task child = await harness.center.create(
    kind: TaskKind.subAgent,
    description: 'child',
    parentTaskId: root.id,
  );
  final Task done = await harness.center.create(
    kind: TaskKind.custom,
    description: 'done',
    parentTaskId: root.id,
  );
  await harness.center.update(done.id, status: TaskStatus.completed);
  for (final Task task in <Task>[root, child, done]) {
    harness.ids(task.id);
  }
  var callbackRan = false;
  harness.center.registerCancel(child.id, () async => callbackRan = true);
  await harness.center.cancel(root.id);
  return <String, Object?>{
    'scenario': 'cascade-cancel',
    'label': '级联取消活跃子任务并执行取消回调（已终态子任务不动）',
    'expect': <String, Object?>{
      'statuses': <String>[
        harness.center.get(root.id)!.status.name,
        harness.center.get(child.id)!.status.name,
        harness.center.get(done.id)!.status.name,
      ],
      'root': _task(harness.center.get(root.id)!, harness.ids),
      'child': _task(harness.center.get(child.id)!, harness.ids),
      'callbackRan': callbackRan,
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

Future<Map<String, Object?>> _shellApprovalCase() async {
  final _RecordingApproval denial = _RecordingApproval(false);
  final _Harness denied = _Harness(approval: denial);
  final Task shell = await denied.center.create(
    kind: TaskKind.shell,
    description: 'rm -rf build',
  );
  var deniedCode = '';
  try {
    await denied.center.cancel(shell.id);
  } catch (error) {
    deniedCode = _errorCode(error);
  }
  final _RecordingApproval grant = _RecordingApproval(true);
  final _Harness granted = _Harness(approval: grant);
  final Task sleeper = await granted.center.create(
    kind: TaskKind.shell,
    description: 'sleep 1',
  );
  await granted.center.cancel(sleeper.id);
  final String normalizedId = granted.ids(sleeper.id);
  return <String, Object?>{
    'scenario': 'shell-approval',
    'label': 'shell 类任务取消走 approval，拒绝抛 cancelled 且状态不动',
    'expect': <String, Object?>{
      'deniedCode': deniedCode,
      'deniedStatus': denied.center.get(shell.id)!.status.name,
      'deniedRequests': denial.requests.length,
      'grantedStatus': granted.center.get(sleeper.id)!.status.name,
      'grantedRequests': grant.requests.length,
      'approvalRequest': <String, Object?>{
        'id': 'cancel-$normalizedId',
        'toolName': grant.requests.single.toolName,
        'arguments': <String, Object?>{
          for (final MapEntry<String, Object?> entry
              in grant.requests.single.arguments.entries)
            entry.key: entry.key == 'id' ? normalizedId : entry.value,
        },
        'description': grant.requests.single.description,
      },
    },
  };
}

Future<Map<String, Object?>> _nonShellNoApprovalCase() async {
  final _RecordingApproval denial = _RecordingApproval(false);
  final _Harness harness = _Harness(approval: denial);
  final Task custom = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  await harness.center.cancel(custom.id);
  return <String, Object?>{
    'scenario': 'non-shell',
    'label': '非 shell 类任务不经 approval',
    'expect': <String, Object?>{
      'status': harness.center.get(custom.id)!.status.name,
      'requests': denial.requests.length,
    },
  };
}

Future<Map<String, Object?>> _cancelTerminalCase() async {
  final _Harness harness = _Harness();
  final Task task = await harness.center.create(
    kind: TaskKind.custom,
    description: 'x',
  );
  await harness.center.update(task.id, status: TaskStatus.completed);
  var code = '';
  try {
    await harness.center.cancel(task.id);
  } catch (error) {
    code = _errorCode(error);
  }
  var missingCode = '';
  try {
    await harness.center.cancel('nope');
  } catch (error) {
    missingCode = _errorCode(error);
  }
  return <String, Object?>{
    'scenario': 'cancel-guards',
    'label': '终态任务再取消抛 already-terminal；未知任务抛 not-found',
    'expect': <String, Object?>{'codes': <String>[code, missingCode]},
  };
}

// ───────────────────────────── 会话恢复 ─────────────────────────────

/// kind = restore：折叠 ownEvents、fork 不继承、陈旧任务改判。
Map<String, Object?> _restore() {
  return <String, Object?>{
    'name': 'restore',
    'kind': 'restore',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'fold',
        'label': '按任务 id 折叠最后一个事件',
        'expect': _foldCase(),
      },
      <String, Object?>{
        'scenario': 'fork',
        'label': 'fork 不继承：只折叠会话自身后缀',
        'expect': _forkCase(),
      },
      <String, Object?>{
        'scenario': 'auto-restore',
        'label': '构造时自动恢复：未完成任务标记 failed',
        'expect': _autoRestoreCase(),
      },
    ],
  };
}

Map<String, Object?> _foldCase() {
  final Session session = Session(id: 's1');
  final _Ids ids = _Ids();
  final Task first = _sample();
  final Task updated = first.copyWith(status: TaskStatus.completed);
  session.append(kTaskEvent, data: first.toJson());
  session.append('goal/changed', data: <String, Object?>{'x': 1});
  session.append(kTaskEvent, data: updated.toJson());
  session.append(kTaskEvent,
      data: _sample().toJson()..['id'] = 't2');
  final Map<String, Task> restored = restoreTaskState(session);
  return <String, Object?>{
    'ids': <String>[for (final String id in restored.keys) id],
    'normalized': <Object?>[for (final Task task in restored.values) _task(task, ids)],
    'statuses': <String>[
      for (final Task task in restored.values) task.status.name,
    ],
  };
}

Map<String, Object?> _forkCase() {
  final Session parent = Session(id: 'p1')
    ..append(kTaskEvent, data: _sample().toJson());
  final Session fork = parent.fork(id: 'f1');
  return <String, Object?>{
    'forked': restoreTaskState(fork).length,
    'parent': restoreTaskState(parent).length,
  };
}

Map<String, Object?> _autoRestoreCase() {
  final Session session = Session(id: 's1');
  final InMemoryTelemetry telemetry = InMemoryTelemetry();
  final _Ids ids = _Ids();
  final Task stale = Task(
    id: 'stale-1',
    kind: TaskKind.shell,
    status: TaskStatus.running,
    description: 'sleep 100',
    createdAt: DateTime(2026, 9, 17, 10),
    startedAt: DateTime(2026, 9, 17, 10),
  );
  final Task done = Task(
    id: 'done-1',
    kind: TaskKind.custom,
    status: TaskStatus.completed,
    description: 'x',
    createdAt: DateTime(2026, 9, 17, 10),
  );
  session.append(kTaskEvent, data: stale.toJson());
  session.append(kTaskEvent, data: done.toJson());
  final DefaultTaskCenter center = DefaultTaskCenter(
    session: session,
    telemetry: telemetry,
  );
  return <String, Object?>{
    'stale': _task(center.get('stale-1')!, ids),
    'done': _task(center.get('done-1')!, ids),
    'staleErrorIsStaleReason': center.get('stale-1')!.error == kTaskStaleReason,
    'log': _log(session, ids),
    'telemetry': _telemetry(telemetry),
    'active': center.active.length,
  };
}

// ───────────────────────────── 模型侧工具 ─────────────────────────────

/// kind = task-tools：播报文本 / list_tasks 过滤 / cancel_task 结局。
Future<Map<String, Object?>> _taskTools() async {
  return <String, Object?>{
    'name': 'task-tools',
    'kind': 'task-tools',
    'cases': <Object?>[
      _describeCases(),
      ...await _listCases(),
      ...await _cancelCases(),
    ],
  };
}

Map<String, Object?> _describeCases() {
  final DateTime created = DateTime.parse('2026-09-17T10:00:00.000Z');
  Task build({
    required String id,
    required TaskKind kind,
    required TaskStatus status,
    required String description,
    Duration? ran,
    Object? result,
  }) =>
      Task(
        id: id,
        kind: kind,
        status: status,
        description: description,
        createdAt: created,
        startedAt: ran == null ? null : created,
        finishedAt: ran == null ? null : created.add(ran),
        result: result,
      );
  final List<Task> tasks = <Task>[
    build(
      id: 't1',
      kind: TaskKind.agentTurn,
      status: TaskStatus.running,
      description: '查机票',
      ran: const Duration(minutes: 3, seconds: 20),
    ),
    build(
      id: 't2',
      kind: TaskKind.shell,
      status: TaskStatus.completed,
      description: 'npm test',
      ran: const Duration(seconds: 42),
      result: <String, Object?>{'exitCode': 0},
    ),
    build(
      id: 't3',
      kind: TaskKind.subAgent,
      status: TaskStatus.failed,
      description: '盯快递',
    ),
  ];
  return <String, Object?>{
    'scenario': 'describe',
    'label': 'describeTasks 播报文本（空 / 多任务 / 未开始无时长）',
    'expect': <String, Object?>{
      'empty': describeTasks(<Task>[]),
      'text': describeTasks(tasks),
    },
  };
}

Future<List<Map<String, Object?>>> _listCases() async {
  final _Harness harness = _Harness();
  final Task running = await harness.center.create(
    kind: TaskKind.agentTurn,
    description: '查机票',
  );
  await harness.center.update(running.id, status: TaskStatus.running);
  await harness.center.create(
    kind: TaskKind.subAgent,
    description: '盯快递',
    parentTaskId: running.id,
  );
  final Task shell = await harness.center.create(
    kind: TaskKind.shell,
    description: 'npm test',
  );
  await harness.center.update(shell.id, status: TaskStatus.completed);
  final ListTasksTool tool = ListTasksTool(taskCenter: harness.center);
  final String parentId = harness.ids(running.id);
  return <Map<String, Object?>>[
    for (final MapEntry<String, Map<String, Object?>> entry
        in <String, Map<String, Object?>>{
      '无过滤列出全部任务': <String, Object?>{},
      '按状态过滤': <String, Object?>{'status': 'running'},
      '按类型过滤': <String, Object?>{'kind': 'subAgent'},
      '按父任务过滤': <String, Object?>{'parent_id': running.id},
      '组合过滤无命中': <String, Object?>{
        'status': 'paused',
        'kind': 'shell',
      },
    }.entries)
      <String, Object?>{
        'scenario': 'list',
        'label': 'list_tasks：${entry.key}',
        'arguments': <String, Object?>{
          for (final MapEntry<String, Object?> argument in entry.value.entries)
            argument.key:
                argument.key == 'parent_id' ? parentId : argument.value,
        },
        'expect': <String, Object?>{
          'content': (await tool.call(
            ToolContext(ToolCall(
                name: kListTasksToolName, arguments: entry.value)),
          ))
              .content,
          'failed': (await tool.call(
            ToolContext(ToolCall(
                name: kListTasksToolName, arguments: entry.value)),
          ))
              .isError,
        },
      },
  ];
}

Future<List<Map<String, Object?>>> _cancelCases() async {
  final _Harness harness = _Harness();
  final Task running = await harness.center.create(
    kind: TaskKind.agentTurn,
    description: '查机票',
  );
  await harness.center.update(running.id, status: TaskStatus.running);
  final CancelTaskTool tool = CancelTaskTool(taskCenter: harness.center);
  final ToolResult cancelled = await tool.call(
      ToolContext(ToolCall(name: kCancelTasksToolName,
          arguments: <String, Object?>{'id': running.id})));
  final ToolResult missing = await tool.call(ToolContext(
      ToolCall(name: kCancelTasksToolName,
          arguments: <String, Object?>{'id': 'nope'})));
  final _RecordingApproval denial = _RecordingApproval(false);
  final _Harness shellHarness = _Harness(approval: denial);
  final Task shell = await shellHarness.center.create(
    kind: TaskKind.shell,
    description: 'sleep 99',
  );
  final ToolResult denied = await CancelTaskTool(taskCenter: shellHarness.center)
      .call(ToolContext(ToolCall(name: kCancelTasksToolName,
          arguments: <String, Object?>{'id': shell.id})));
  return <Map<String, Object?>>[
    <String, Object?>{
      'scenario': 'cancel-ok',
      'label': 'cancel_task 成功口语化确认',
      'expect': <String, Object?>{
        'content': cancelled.content,
        'isError': cancelled.isError,
        'status': harness.center.get(running.id)!.status.name,
      },
    },
    <String, Object?>{
      'scenario': 'cancel-missing',
      'label': 'cancel_task 任务不存在返回失败结果',
      'expect': <String, Object?>{
        'content': missing.content,
        'isError': missing.isError,
        'code': missing.error!.code,
      },
    },
    <String, Object?>{
      'scenario': 'cancel-denied',
      'label': 'cancel_task 审批拒绝时透传 cancelled',
      'expect': <String, Object?>{
        'content': denied.content,
        'isError': denied.isError,
        'code': denied.error!.code,
        'status': shellHarness.center.get(shell.id)!.status.name,
      },
    },
  ];
}

// ───────────────────────────── 运行时接入 ─────────────────────────────

/// kind = tracking-flow：轮次追踪 / spawn_agent 中间件 / schedule 交付 / shell 装饰器。
Future<Map<String, Object?>> _trackingFlow() async {
  return <String, Object?>{
    'name': 'tracking-flow',
    'kind': 'tracking-flow',
    'cases': <Object?>[
      await _turnCompletedCase(),
      await _turnFailedCase(),
      await _spawnAgentCase(),
      await _spawnAgentFailedCase(),
      await _scheduleDeliveryCase(),
      ...await _shellCases(),
    ],
  };
}

Future<Map<String, Object?>> _turnCompletedCase() async {
  final _Harness harness = _Harness();
  final TaskTracking tracking = TaskTracking(tasks: harness.center);
  final AgentLoop loop = AgentLoop(
    llm: _ScriptedProvider(<LlmResult>[_text('你好')]),
    tools: ToolRegistry(),
  )..turnTracker = tracking;
  final AgentTurn turn = await loop.run('在吗');
  return <String, Object?>{
    'scenario': 'turn-ok',
    'label': '一轮收口：agentTurn 任务 completed，结果带回复',
    'expect': <String, Object?>{
      'reply': turn.reply,
      'task': _task(harness.center.all.single, harness.ids),
      'currentTurnTaskId': tracking.currentTurnTaskId,
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

Future<Map<String, Object?>> _turnFailedCase() async {
  final _Harness harness = _Harness();
  final TaskTracking tracking = TaskTracking(tasks: harness.center);
  final Session session = Session(id: 's1')..close();
  final AgentLoop loop = AgentLoop(
    llm: _ScriptedProvider(<LlmResult>[_text('x')]),
    tools: ToolRegistry(),
    session: session,
  )..turnTracker = tracking;
  var thrown = '';
  try {
    await loop.run('hi');
  } catch (error) {
    thrown = _errorCode(error);
  }
  return <String, Object?>{
    'scenario': 'turn-failed',
    'label': '一轮失败：agentTurn 任务 failed 并带错误',
    'expect': <String, Object?>{
      'threw': thrown.isNotEmpty,
      'task': _task(harness.center.all.single, harness.ids),
      'log': _log(harness.session, harness.ids),
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

Future<Map<String, Object?>> _spawnAgentCase() async {
  final Context host = Context.root();
  final _Harness harness = _Harness();
  final ToolRegistry registry = ToolRegistry();
  registry.register(SpawnAgentTool(
    host: host,
    llm: _ScriptedProvider(<LlmResult>[_text('结论：最低 720 元')]),
    tools: registry,
  ));
  final TaskTracking tracking = TaskTracking(tasks: harness.center);
  registry.use(tracking.spawnAgentMiddleware);
  await tracking.beginTurn('查机票');
  final ToolResult result = await registry.call(const ToolCall(
    name: kSpawnAgentToolName,
    arguments: <String, Object?>{'task': '查明天机票', 'max_rounds': 3},
  ));
  await tracking.endTurn(result: result.content);
  host.dispose();
  final Task turn = harness.center.all
      .firstWhere((Task task) => task.kind == TaskKind.agentTurn);
  final Task sub = harness.center.all
      .firstWhere((Task task) => task.kind == TaskKind.subAgent);
  for (final Task task in <Task>[turn, sub]) {
    harness.ids(task.id);
  }
  return <String, Object?>{
    'scenario': 'spawn-ok',
    'label': '委托建 subAgent 任务，挂在当前轮次下并落定',
    'expect': <String, Object?>{
      'toolIsError': result.isError,
      'turn': _task(turn, harness.ids),
      'sub': _task(sub, harness.ids),
      'telemetry': _telemetry(harness.telemetry),
    },
  };
}

Future<Map<String, Object?>> _spawnAgentFailedCase() async {
  final Context host = Context.root();
  final _Harness harness = _Harness();
  final ToolRegistry registry = ToolRegistry();
  registry.register(SpawnAgentTool(
    host: host,
    llm: _ThrowingProvider(),
    tools: registry,
  ));
  final TaskTracking tracking = TaskTracking(tasks: harness.center);
  registry.use(tracking.spawnAgentMiddleware);
  final ToolResult result = await registry.call(const ToolCall(
    name: kSpawnAgentToolName,
    arguments: <String, Object?>{'task': '必失败'},
  ));
  host.dispose();
  final Task sub = harness.center.all
      .firstWhere((Task task) => task.kind == TaskKind.subAgent);
  return <String, Object?>{
    'scenario': 'spawn-failed',
    'label': '子 Agent 失败时 subAgent 任务 failed（从结果值判定）',
    'expect': <String, Object?>{
      'toolIsError': result.isError,
      'sub': _task(sub, harness.ids),
      'errorContainsSubFailure': '${sub.error}'.contains('子 Agent 失败'),
    },
  };
}

Future<Map<String, Object?>> _scheduleDeliveryCase() async {
  final _Harness harness = _Harness();
  var calls = 0;
  final ScheduleDelivery deliver = trackScheduleDelivery(
    harness.center,
    (String text) async {
      calls++;
      return calls == 1;
    },
  );
  final bool first = await deliver('该喝水了');
  final bool second = await deliver('该喝水了');
  return <String, Object?>{
    'scenario': 'schedule-delivery',
    'label': '提醒交付成功 completed，被拒 failed',
    'expect': <String, Object?>{
      'delivered': <bool>[first, second],
      'tasks': _tasks(
        harness.center.all
            .where((Task task) => task.kind == TaskKind.schedule)
            .toList(),
        harness.ids,
      ),
    },
  };
}

Future<List<Map<String, Object?>>> _shellCases() async {
  final _Harness foreground = _Harness();
  final LocalShellExecutor local = LocalShellExecutor();
  final TrackingShellExecutor executor = TrackingShellExecutor(
    inner: local,
    tasks: foreground.center,
  );
  final ShellRunResult run = await executor.run(executor.resolve(
      const ShellExecRequest(command: 'echo hello', timeoutMs: 10000)));
  final _Harness background = _Harness();
  final LocalShellExecutor local2 = LocalShellExecutor();
  final TrackingShellExecutor executor2 = TrackingShellExecutor(
    inner: local2,
    tasks: background.center,
  );
  final ShellProcess process = await executor2.start(executor2.resolve(
      const ShellExecRequest(command: 'sleep 30')));
  process.kill();
  await process.done;
  final Task killed = background.center.all.single;
  await _waitTerminal(background.center, killed.id);
  final Task settled = background.center.get(killed.id)!;
  return <Map<String, Object?>>[
    <String, Object?>{
      'scenario': 'shell-foreground',
      'label': '前台执行按退出码落定',
      'command': 'echo hello',
      'expect': <String, Object?>{
        'exitCode': run.exitCode,
        'task': _task(foreground.center.all.single, foreground.ids),
      },
    },
    <String, Object?>{
      // 被信号杀死的退出码随平台而异（macOS/Linux 为 -9），故只投影形态。
      'scenario': 'shell-killed',
      'label': '后台进程被 kill 落 failed（退出码随平台而异，只比对形态）',
      'command': 'sleep 30',
      'expect': <String, Object?>{
        'kind': settled.kind.name,
        'status': settled.status.name,
        'description': settled.description,
        'metadata': settled.metadata,
        'hasFinishedAt': settled.finishedAt != null,
        'resultKeys': (settled.result! as Map<String, Object?>).keys.toList(),
      },
    },
  ];
}

Future<void> _waitTerminal(DefaultTaskCenter center, String id) async {
  final Stopwatch watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 5)) {
    final Task? task = center.get(id);
    if (task != null && task.isTerminal) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('任务 $id 未在 5 秒内落定');
}

// ───────────────────────────── 脚本化模型替身 ─────────────────────────────

LlmResult _text(String content) =>
    LlmResult(content: content, provider: 'scripted', model: 'm');

class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider(this.script);

  final List<LlmResult> script;
  int _calls = 0;

  @override
  String get name => 'scripted';

  @override
  Future<LlmResult> chat(
    List<LlmMessage> messages, {
    Map<String, dynamic>? options,
    List<Map<String, dynamic>>? tools,
  }) async {
    _calls++;
    final int index = _calls - 1 < script.length ? _calls - 1 : script.length - 1;
    return script[index];
  }

  @override
  Stream<LlmStreamEvent> chatStream(
    List<LlmMessage> messages, {
    Map<String, dynamic>? options,
    List<Map<String, dynamic>>? tools,
  }) =>
      const Stream<LlmStreamEvent>.empty();

  @override
  void close() {}
}

class _ThrowingProvider implements LlmProvider {
  @override
  String get name => 'throwing';

  @override
  Future<LlmResult> chat(
    List<LlmMessage> messages, {
    Map<String, dynamic>? options,
    List<Map<String, dynamic>>? tools,
  }) =>
      Future<LlmResult>.error(StateError('模型不可用'));

  @override
  Stream<LlmStreamEvent> chatStream(
    List<LlmMessage> messages, {
    Map<String, dynamic>? options,
    List<Map<String, dynamic>>? tools,
  }) =>
      const Stream<LlmStreamEvent>.empty();

  @override
  void close() {}
}
