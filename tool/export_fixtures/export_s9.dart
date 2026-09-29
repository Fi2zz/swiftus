// S9 Cron golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 用例自带输入；规则与到期判定是纯函数，故以「显式 now / startedAt / firedAt」驱动，
// 不依赖真实墙钟与定时器。
//
// 归一化（S9 专用）：
// - 时刻一律用输入里给定的固定时刻，投影里逐字保留（UTC ISO 串），不归一化；
// - **生成的 id 不进投影**（含毫秒与随机后缀），只断言 id 形状与唯一性；
// - 工具结果的 JSON 文本逐字比对（framing 属协议文本，不许改写）。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_cron/conatus_cron.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'cron-parse': _cronParse,
    'cron-rules': _cronRules,
    'cron-registry': _cronRegistry,
    'cron-history': _cronHistory,
    'cron-message': _cronMessage,
    'cron-runtime': _cronRuntime,
    'cron-tools': _cronTools,
  };
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, Future<Map<String, Object?>> Function()> entry
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s9');
}

String _code(Object error) =>
    error is CronException ? error.code : error.runtimeType.toString();

/// 尽力执行并把异常收敛成 `{error: 码}`。
Future<Object?> _guard(Future<Object?> Function() body) async {
  try {
    return await body();
  } catch (error) {
    return <String, Object?>{'error': _code(error)};
  }
}

// ───────────────────────────── 表达式引擎 ─────────────────────────────

/// kind = cron-parse：字段解析、匹配、下一分钟搜索。
Future<Map<String, Object?>> _cronParse() async {
  List<Object?> parseCase(String expression) => <Object?>[
        <String, Object?>{
          'parsed': parseCronExpression(expression) != null,
          'fields': _fieldsOf(expression),
          'domStar': parseCronExpression(expression)?.domStar,
          'dowStar': parseCronExpression(expression)?.dowStar,
        },
      ];

  return <String, Object?>{
    'name': 'cron-parse',
    'kind': 'cron-parse',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'parse',
        'label': '合法表达式：五段、集合展开、周日 7 归一为 0、裸星标记',
        'input': <Object?>[
          '*/15 * * * *',
          '0 9 * * 1-5',
          '0 0 1 1 *',
          '30 2 29 2 *',
          '0 12 * * 7',
          '0,30 8-9 1,15 1,6 0',
          '0 9 * * 1-5/2',
          '5 4 * * 1/3',
          '0 0 * * *',
        ],
        'expect': <Object?>[
          for (final String expression in <String>[
            '*/15 * * * *',
            '0 9 * * 1-5',
            '0 0 1 1 *',
            '30 2 29 2 *',
            '0 12 * * 7',
            '0,30 8-9 1,15 1,6 0',
            '0 9 * * 1-5/2',
            '5 4 * * 1/3',
            '0 0 * * *',
          ])
            ...parseCase(expression),
        ],
      },
      <String, Object?>{
        'scenario': 'parse',
        'label': '非法表达式：段数不对、越界、步进为零、空片段',
        'input': <Object?>[
          '* * * *',
          '* * * * * *',
          '60 * * * *',
          '* 24 * * *',
          '* * 0 * *',
          '* * * 13 *',
          '* * * * 8',
          '*/0 * * * *',
          '5-1 * * * *',
          '1,,2 * * * *',
          '  ',
        ],
        'expect': <Object?>[
          for (final String expression in <String>[
            '* * * *',
            '* * * * * *',
            '60 * * * *',
            '* 24 * * *',
            '* * 0 * *',
            '* * * 13 *',
            '* * * * 8',
            '*/0 * * * *',
            '5-1 * * * *',
            '1,,2 * * * *',
            '  ',
          ])
            <String, Object?>{'parsed': parseCronExpression(expression) != null},
        ],
      },
      <String, Object?>{
        'scenario': 'match',
        'label': '匹配：分/时/月/日/周，日与周同时受限时任一匹配',
        'input': _matchCases(),
        'expect': <Object?>[
          for (final Map<String, Object?> row in _matchCases())
            row['expect'],
        ],
      },
      <String, Object?>{
        'scenario': 'next-slot',
        'label': '下一触发分钟：严格大于锚点、本地时间语义',
        'input': _nextCases(),
        'expect': <Object?>[
          for (final Map<String, Object?> row in _nextCases())
            row['expect'],
        ],
      },
    ],
  };
}

Map<String, Object?>? _fieldsOf(String expression) {
  final CronExpression? parsed = parseCronExpression(expression);
  if (parsed == null) return null;
  return <String, Object?>{
    'minute': _sorted(parsed.minute),
    'hour': _sorted(parsed.hour),
    'dom': _sorted(parsed.dom),
    'month': _sorted(parsed.month),
    'dow': _sorted(parsed.dow),
  };
}

List<int> _sorted(Set<int> values) => values.toList()..sort();

/// 匹配用例：{expression, local} → 期望是否匹配。
List<Map<String, Object?>> _matchCases() {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  void add(String expression, String local) {
    final CronExpression? parsed = parseCronExpression(expression);
    rows.add(<String, Object?>{
      'input': <String, Object?>{'expression': expression, 'local': local},
      'expect': parsed == null
          ? null
          : <String, Object?>{
              'matches': cronMatches(parsed, DateTime.parse(local)),
            },
    });
  }

  add('*/15 * * * *', '2026-03-09T10:15:00');
  add('*/15 * * * *', '2026-03-09T10:16:00');
  add('0 9 * * 1-5', '2026-03-09T09:00:00'); // 周一
  add('0 9 * * 1-5', '2026-03-08T09:00:00'); // 周日
  add('0 9 13 * 5', '2026-03-13T09:00:00'); // 日与周同时受限 → 任一匹配
  add('0 9 14 * 5', '2026-03-13T09:00:00'); // 日与周同时受限 → 任一匹配
  add('0 9 * * *', '2026-03-14T09:00:00'); // 裸星 → 两者都要匹配（日匹配即真）
  add('0 9 13 * 5', '2026-03-14T09:00:00'); // 周六：日不匹配、周不匹配
  return rows;
}

/// 下一触发用例：{expression, after} → 期望时刻（或 null）。
List<Map<String, Object?>> _nextCases() {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  void add(String expression, String after) {
    final CronExpression? parsed = parseCronExpression(expression);
    final DateTime? next =
        parsed == null ? null : nextCronSlot(parsed, DateTime.parse(after));
    rows.add(<String, Object?>{
      'input': <String, Object?>{'expression': expression, 'after': after},
      'expect': <String, Object?>{'next': formatCronInstant(next)},
    });
  }

  add('*/15 * * * *', '2026-03-09T10:00:00Z');
  add('*/15 * * * *', '2026-03-09T10:15:00Z'); // 严格大于：命中下一格
  add('0 9 * * *', '2026-03-09T10:00:00Z');
  add('0 0 29 2 *', '2026-01-01T00:00:00Z'); // 四年内无匹配（2028 才是闰年）
  add('0 0 29 2 *', '2028-02-28T00:00:00Z');
  return rows;
}

// ───────────────────────────── 规则与到期判定 ─────────────────────────────

/// 造一个内部任务（不落盘、不经服务入口）。
CronTask _task({
  required String id,
  String? at,
  num? every,
  String? daily,
  String? cron,
  bool enabled = true,
  bool? enabledOverride,
  String? lastRunAt,
  String? firedAt,
  String? sessionId,
  CronTaskOrigin origin = CronTaskOrigin.dynamic,
}) {
  final CronTask task = CronTask(
    id: id,
    prompt: '做点什么',
    at: at,
    every: every,
    daily: daily,
    cron: cron,
    sessionId: sessionId,
    enabled: enabled,
    origin: origin,
  )
    ..enabledOverride = enabledOverride
    ..lastRunAt = lastRunAt == null ? null : DateTime.parse(lastRunAt)
    ..firedAt = firedAt == null ? null : DateTime.parse(firedAt);
  if (cron != null) {
    task.cronParsed = parseCronExpression(cron);
  }
  return task;
}

Map<String, Object?> _rulesView(
  CronTask task,
  DateTime now,
  DateTime startedAt,
) =>
    buildTaskView(task, now, startedAt).toJson();

/// kind = cron-rules：校验、到期判定、下次触发、id 生成。
Future<Map<String, Object?>> _cronRules() async {
  final DateTime now = DateTime.parse('2026-03-09T10:00:00Z');
  final DateTime startedAt = DateTime.parse('2026-03-09T08:00:00Z');

  final List<Object?> validations = <Object?>[
    for (final Map<String, Object?> input in <Map<String, Object?>>[
      <String, Object?>{'id': 'a', 'prompt': 'p', 'every': 10},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'every': 10.5},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'every': 9},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'at': '2026-03-09T11:00:00Z'},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'at': '不是时刻'},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'daily': '09:30'},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'daily': '24:00'},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'daily': '9:30'},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'cron': '*/5 * * * *'},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'cron': 'bad'},
      <String, Object?>{'id': '9bad', 'prompt': 'p', 'every': 10},
      <String, Object?>{'id': '', 'prompt': 'p', 'every': 10},
      <String, Object?>{'id': 'a', 'prompt': '   ', 'every': 10},
      <String, Object?>{'id': 'a', 'prompt': 'p'},
      <String, Object?>{
        'id': 'a',
        'prompt': 'p',
        'every': 10,
        'daily': '09:00',
      },
      <String, Object?>{'id': 'a', 'prompt': 'p', 'every': 0},
      <String, Object?>{'id': 'a', 'prompt': 'p', 'daily': ''},
    ])
      validateTaskInput((
        id: input['id'],
        prompt: input['prompt'],
        at: input['at'],
        every: input['every'],
        daily: input['daily'],
        cron: input['cron'],
      )),
  ];

  // 到期判定矩阵：每个任务在固定 now 下的 dueSlot / nextRunAt。
  final List<Map<String, Object?>> dueRows =
      <Map<String, Object?>>[
    <String, Object?>{'label': 'at：未到点', 'task': _task(id: 't1', at: '2026-03-09T11:00:00Z')},
    <String, Object?>{'label': 'at：到点即触发', 'task': _task(id: 't2', at: '2026-03-09T09:00:00Z')},
    <String, Object?>{
      'label': 'at：已消费不再触发',
      'task': _task(id: 't3', at: '2026-03-09T09:00:00Z', firedAt: '2026-03-09T09:00:00Z'),
    },
    <String, Object?>{'label': 'every：未到间隔', 'task': _task(id: 't4', every: 600, lastRunAt: '2026-03-09T09:55:00Z')},
    <String, Object?>{'label': 'every：到间隔', 'task': _task(id: 't5', every: 600, lastRunAt: '2026-03-09T09:50:00Z')},
    <String, Object?>{'label': 'every：从未运行，以装配时刻为锚', 'task': _task(id: 't6', every: 3600)},
    <String, Object?>{
      'label': 'every：允许小数间隔',
      'task': _task(id: 't7', every: 10.5, lastRunAt: '2026-03-09T09:59:56Z'),
    },
    <String, Object?>{'label': 'daily：今天这格未到', 'task': _task(id: 't8', daily: '11:00')},
    <String, Object?>{'label': 'daily：今天这格已过且未运行 → 补发', 'task': _task(id: 't9', daily: '09:00')},
    <String, Object?>{
      'label': 'daily：今天这格已消费 → 不再补发',
      'task': _task(id: 't10', daily: '09:00', lastRunAt: '2026-03-09T09:00:00Z'),
    },
    <String, Object?>{'label': 'cron：未到下一分钟', 'task': _task(id: 't11', cron: '*/15 * * * *')},
    <String, Object?>{
      'label': 'cron：下一分钟已到',
      'task': _task(
        id: 't12',
        cron: '*/15 * * * *',
        lastRunAt: '2026-03-09T09:45:00Z',
      ),
    },
    <String, Object?>{
      'label': '停用覆盖为假 → 不触发且无下次',
      'task': _task(id: 't13', every: 10, enabled: true, enabledOverride: false),
    },
  ];

  return <String, Object?>{
    'name': 'cron-rules',
    'kind': 'cron-rules',
    'now': formatCronInstant(now),
    'startedAt': formatCronInstant(startedAt),
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'validate',
        'label': '输入校验：id 形状、prompt、四选一、规则取值与消息逐字',
        'expect': <String, Object?>{'messages': validations},
      },
      <String, Object?>{
        'scenario': 'due',
        'label': '到期判定与下次触发：at 已消费、every 锚点、daily 补发与已消费、cron 缓存、停用',
        'expect': <Object?>[
          for (final Map<String, Object?> row in dueRows)
            <String, Object?>{
              'label': row['label'],
              'due': formatCronInstant(
                dueSlot(row['task']! as CronTask, now, startedAt),
              ),
              'nextRunAt': _rulesView(
                row['task']! as CronTask,
                now,
                startedAt,
              )['nextRunAt'],
            },
        ],
      },
      <String, Object?>{
        'scenario': 'id-gen',
        'label': '生成 id 的形状与唯一性（值不入 fixture）',
        'expect': <String, Object?>{
          'shapeMatches': RegExp(r'^task-[0-9a-z]+-[0-9a-z]{4}$')
              .hasMatch(generateTaskId(now, 1)),
          'distinctWithSameInstant':
              generateTaskId(now, 1) != generateTaskId(now, 2),
        },
      },
    ],
  };
}

// ───────────────────────────── 注册表与服务 ─────────────────────────────

/// 内存存储（导出器自用，行为与 JsonCronStorage 的快照语义一致）。
class MemoryCronStorage implements CronStorage {
  CronStorageSnapshot snapshot = const CronStorageSnapshot();
  List<Map<String, Object?>> history = <Map<String, Object?>>[];
  int taskSaves = 0;
  int historySaves = 0;
  bool closed = false;

  @override
  CronStorageSnapshot loadTasks() => snapshot;

  @override
  void saveTasks({
    required List<Map<String, Object?>> tasks,
    required Map<String, CronRunStamp> runStamps,
    required Map<String, bool> overrides,
  }) {
    taskSaves += 1;
    snapshot = CronStorageSnapshot(
      dynamicTasks: tasks,
      runStamps: runStamps,
      overrides: overrides,
    );
  }

  @override
  List<Map<String, Object?>> loadHistory() => history;

  @override
  void saveHistory(List<Map<String, Object?>> records) {
    historySaves += 1;
    history = List<Map<String, Object?>>.of(records);
  }

  // 注：CronStorage 端口没有 close 方法（与 Dart 侧一致），这里只是导出器用来自查。
  void close() {
    closed = true;
  }
}

/// kind = cron-registry：装配顺序、增删改、配置任务保护、持久化字段表。
Future<Map<String, Object?>> _cronRegistry() async {
  final DateTime now = DateTime.parse('2026-03-09T10:00:00Z');

  // 装配：损坏的持久任务被跳过并告警，配置任务叠加，运行戳与覆盖恢复。
  final MemoryCronStorage stored = MemoryCronStorage();
  stored.saveTasks(
    tasks: <Map<String, Object?>>[
      <String, Object?>{'id': 'kept', 'prompt': '保留', 'every': 60},
      <String, Object?>{'id': 'broken', 'prompt': '坏', 'every': 1},
      <String, Object?>{'id': 'dup', 'prompt': '与配置撞 id', 'every': 60},
    ],
    runStamps: <String, CronRunStamp>{
      'kept': CronRunStamp(lastRunAt: DateTime.parse('2026-03-09T09:00:00Z')),
    },
    overrides: <String, bool>{'cfg': false},
  );
  final List<String> warnings = <String>[];
  final CronService booted = CronService(
    storage: stored,
    configTasks: <Map<String, Object?>>[
      <String, Object?>{'id': 'cfg', 'prompt': '配置任务', 'daily': '08:00'},
      <String, Object?>{'id': 'dup', 'prompt': '配置里同名', 'every': 120},
    ],
    clock: () => now,
    onWarning: warnings.add,
  );

  // 动态任务 CRUD。
  final MemoryCronStorage storage = MemoryCronStorage();
  final CronService service =
      CronService(storage: storage, clock: () => now, onWarning: warnings.add);
  final CronTaskView added = service.addDynamicTask(<String, Object?>{
    'id': 'dyn-1',
    'prompt': '原提示',
    'every': 30,
    'sessionId': 's1',
  });
  final Object? duplicate = await _guard(() async {
    service.addDynamicTask(<String, Object?>{
      'id': 'dyn-1',
      'prompt': '撞 id',
      'every': 30,
    });
    return 'added';
  });
  final Object? invalid = await _guard(() async {
    service.addDynamicTask(<String, Object?>{
      'id': 'dyn-2',
      'prompt': '间隔太小',
      'every': 5,
    });
    return 'added';
  });
  final CronTaskView editedPromptOnly =
      service.updateDynamicTask('dyn-1', <String, Object?>{'prompt': '新提示'});
  final CronTaskView editedSchedule = service.updateDynamicTask(
    'dyn-1',
    <String, Object?>{'daily': '07:15'},
  );
  final Object? editConfig = await _guard(() async {
    service.updateDynamicTask('cfg', <String, Object?>{'prompt': '改配置'});
    return 'edited';
  });
  final Object? removeConfig = await _guard(() async {
    service.removeDynamicTask('cfg');
    return 'removed';
  });
  final Object? removeMissing = await _guard(() async {
    service.removeDynamicTask('ghost');
    return 'removed';
  });
  final CronTaskView disabled = service.setEnabled('dyn-1', false);
  final CronTaskView reEnabled = service.setEnabled('dyn-1', true);
  service.removeDynamicTask('dyn-1');
  final Object? generatedShape = await _guard(() async {
    final CronTaskView view = service.addDynamicTask(<String, Object?>{
      'prompt': '自动生成 id',
      'every': 60,
    });
    return <String, Object?>{
      'shape': RegExp(r'^task-[0-9a-z]+-[0-9a-z]{4}$').hasMatch(view.id),
      'boundSession': view.sessionId,
      'viewSchedule': view.schedule,
    };
  });

  return <String, Object?>{
    'name': 'cron-registry',
    'kind': 'cron-registry',
    'now': formatCronInstant(now),
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'boot',
        'label': '装配：持久动态任务 → 配置任务 → 运行戳 → 启停覆盖；非法与重 id 跳过并告警',
        'expect': <String, Object?>{
          'ids': [
            for (final CronTask t in booted.tasks) t.id,
          ],
          'warnings': warnings.length,
          'keptLastRunAt': formatCronInstant(
            booted.findTask('kept')?.lastRunAt,
          ),
          'cfgOverride': booted.findTask('cfg')?.enabledOverride,
          'keptOrigin': booted.findTask('kept')?.origin.wire,
          'cfgOrigin': booted.findTask('cfg')?.origin.wire,
        },
      },
      <String, Object?>{
        'scenario': 'crud',
        'label': '动态任务增删改：重 id / 非法输入被拒，改排期重置运行戳，覆盖与声明一致时归空',
        'expect': <String, Object?>{
          'added': added.toJson(),
          'duplicate': duplicate,
          'invalid': invalid,
          'editPromptOnly': editedPromptOnly.toJson(),
          'editSchedule': editedSchedule.toJson(),
          'editConfigTask': editConfig,
          'removeConfigTask': removeConfig,
          'removeMissing': removeMissing,
          'disabled': disabled.toJson(),
          'reEnabled': reEnabled.toJson(),
          'generated': generatedShape,
          'remainingIds': [
            for (final CronTask t in service.tasks) t.id,
          ],
        },
      },
      <String, Object?>{
        'scenario': 'persistence',
        'label': '持久化只写显式字段表：内部缓存不落盘，删任务后表里不再有它',
        'expect': <String, Object?>{
          'savedTaskKeys': storage.loadTasks().dynamicTasks.isEmpty
              ? <String>[]
              : storage
                  .loadTasks()
                  .dynamicTasks
                  .map((Map<String, Object?> t) => t.keys.toList()..sort())
                  .toList(),
          'savedCount': storage.loadTasks().dynamicTasks.length,
        },
      },
    ],
  };
}

// ───────────────────────────── 历史账本 ─────────────────────────────

/// kind = cron-history：seq 连续、归还、封顶、finish 推进、limit 退化。
Future<Map<String, Object?>> _cronHistory() async {
  final DateTime now = DateTime.parse('2026-03-09T10:00:00Z');
  final MemoryCronStorage storage = MemoryCronStorage();
  final CronService service = CronService(storage: storage, clock: () => now);

  // 预分配 → 归还 → 再分配：seq 必须连续。
  final CronRecordRef first = service.allocateRecordRef(now);
  service.releaseRecordRef(first);
  final CronRecordRef second = service.allocateRecordRef(now);
  final CronRunRecord committed = service.commitFire(
    ref: second,
    taskId: 't1',
    slot: now,
    firedAt: now,
  );

  // finish 推进 + 摘要截断（300 字符上限）。
  final CronRunRecord? finished = service.finishRun(
    committed.id,
    ok: true,
    excerpt: 'x' * 350,
  );
  final CronRunRecord? failed = service.finishRun(
    committed.id,
    ok: false,
  );
  final CronRunRecord? missing = service.finishRun('run-999-zz', ok: true);

  // limit 退化：缺省 / 非法 → 100，超过上限 → 500。
  final List<int> caps = <int>[
    service.listHistory().length,
    service.listHistory(limit: 0).length,
    service.listHistory(limit: -5).length,
    service.listHistory(limit: 3).length,
    service.listHistory(limit: 9999).length,
  ];

  return <String, Object?>{
    'name': 'cron-history',
    'kind': 'cron-history',
    'now': formatCronInstant(now),
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'ledger',
        'label': '账本：seq 预分配与归还保持连续、记录序列化、finish 推进与摘要截断、未知 id 返回空',
        'expect': <String, Object?>{
          'firstSeqReleased': first.seq,
          'secondSeq': second.seq,
          'recordIdShape': RegExp(r'^run-\d+-[0-9a-z]+$').hasMatch(committed.id),
          'record': committed.toJson(),
          'finishedStatus': finished?.status,
          'excerptLength': finished?.excerpt?.length,
          'failedStatusOnMissing': failed == null ? 'null' : failed.status,
          'missingRecord': missing == null ? 'null' : 'record',
        },
      },
      <String, Object?>{
        'scenario': 'limit',
        'label': 'list 的 limit 退化：缺省与非法 → 100，超过上限 → 500',
        'expect': <String, Object?>{'caps': caps},
      },
    ],
  };
}

// ───────────────────────────── framing 与视图 ─────────────────────────────

/// kind = cron-message：framing 逐字与视图形状。
Future<Map<String, Object?>> _cronMessage() async {
  final DateTime now = DateTime.parse('2026-03-09T10:00:00Z');
  final DateTime startedAt = DateTime.parse('2026-03-09T08:00:00Z');

  final Map<String, Object?> daily = _rulesView(
    _task(
      id: 't-daily',
      daily: '07:00',
      sessionId: 's9',
      lastRunAt: '2026-03-08T07:00:00Z',
    ),
    now,
    startedAt,
  );
  final Map<String, Object?> fired = _rulesView(
    _task(id: 't-at', at: '2026-03-09T09:00:00Z', firedAt: '2026-03-09T09:00:00Z'),
    now,
    startedAt,
  );
  final Map<String, Object?> cronView = _rulesView(
    _task(id: 't-cron', cron: '*/15 * * * *'),
    now,
    startedAt,
  );

  return <String, Object?>{
    'name': 'cron-message',
    'kind': 'cron-message',
    'now': formatCronInstant(now),
    'startedAt': formatCronInstant(startedAt),
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'view',
        'label': '模型可见视图：schedule 四选一、daily 已消费顺延一天、at 已消费无下次',
        'expect': <String, Object?>{
          'daily': daily,
          'firedAt': fired,
          'cron': cronView,
        },
      },
      <String, Object?>{
        'scenario': 'framing',
        'label': '触发 framing 逐行固定（防注入设计，不许改写）',
        'expect': <String, Object?>{
          'framing': renderTaskMessage(
            id: 't-1',
            prompt: '把昨天的会议纪要发出去',
            slot: DateTime.parse('2026-03-09T09:00:00Z'),
            firedAt: DateTime.parse('2026-03-09T09:00:01Z'),
          ),
        },
      },
    ],
  };
}

// ───────────────────────────── 运行时与工具 ─────────────────────────────

/// kind = cron-runtime / cron-tools：tick 扫描、投递被拒不消费时段、工具结果形状。
Future<Map<String, Object?>> _cronRuntime() async {
  final DateTime now = DateTime.parse('2026-03-09T10:00:00Z');
  final List<String> warnings = <String>[];
  final List<String> delivered = <String>[];

  // accept=false：到期但不消费时段（下次 tick 仍到期）。
  final MemoryCronStorage refuseStorage = MemoryCronStorage();
  final CronService refusing = CronService(
    storage: refuseStorage,
    clock: () => now,
    onWarning: warnings.add,
  );
  refusing.addDynamicTask(<String, Object?>{
    'id': 'refused',
    'prompt': '被拒',
    'every': 600,
  });
  bool accept = false;
  final CronRuntime refusingRuntime = CronRuntime(
    service: refusing,
    deliver: (String recordId, String framing, CronTask task) async {
      delivered.add('${task.id}:$recordId');
      return accept;
    },
    options: CronRuntimeOptions(
      clock: () => now,
      onWarning: warnings.add,
      tickSeconds: 1,
      firstTickDelay: Duration.zero,
    ),
  );
  refusingRuntime.dispose(); // 只用手动 tick，不留定时器
  await refusingRuntime.tick();
  final Object? afterRefuse = <String, Object?>{
    'lastRunAt': formatCronInstant(refusing.findTask('refused')?.lastRunAt),
    'historyCount': refusing.listHistory().length,
    'warned': warnings.length,
  };
  accept = true;
  await refusingRuntime.tick();
  final Map<String, Object?> afterAccept = <String, Object?>{
    'lastRunAt': formatCronInstant(refusing.findTask('refused')?.lastRunAt),
    'historyCount': refusing.listHistory().length,
    'deliveredCount': delivered.length,
  };

  // 投递抛错：不消费时段，走告警。
  final MemoryCronStorage throwStorage = MemoryCronStorage();
  final CronService throwing = CronService(
    storage: throwStorage,
    clock: () => now,
    onWarning: warnings.add,
  );
  throwing.addDynamicTask(<String, Object?>{'id': 'boom', 'prompt': '抛错', 'every': 600});
  final CronRuntime throwingRuntime = CronRuntime(
    service: throwing,
    deliver: (String recordId, String framing, CronTask task) async =>
        throw StateError('host down'),
    options: CronRuntimeOptions(
      clock: () => now,
      onWarning: warnings.add,
      tickSeconds: 1,
      firstTickDelay: Duration.zero,
    ),
  );
  throwingRuntime.dispose();
  await throwingRuntime.tick();
  final Map<String, Object?> afterThrow = <String, Object?>{
    'lastRunAt': formatCronIntervalTask(throwing),
    'historyCount': throwing.listHistory().length,
  };

  // 单任务故障隔离：一个任务抛错不阻断其他任务。
  final MemoryCronStorage isolated = MemoryCronStorage();
  final CronService isolateService = CronService(
    storage: isolated,
    clock: () => now,
  );
  isolateService.addDynamicTask(<String, Object?>{'id': 'ok-1', 'prompt': '好的', 'every': 600});
  final CronRuntime isolateRuntime = CronRuntime(
    service: isolateService,
    deliver: (String recordId, String framing, CronTask task) async {
      if (task.id == 'bad') throw StateError('boom');
      return true;
    },
    options: CronRuntimeOptions(
      clock: () => now,
      onWarning: warnings.add,
      tickSeconds: 1,
      firstTickDelay: Duration.zero,
    ),
  );
  isolateRuntime.dispose();
  isolateService.addDynamicTask(<String, Object?>{'id': 'bad', 'prompt': '坏的', 'every': 600});
  await isolateRuntime.tick();
  final Map<String, Object?> isolation = <String, Object?>{
    'goodDelivered': isolateService.listHistory().length,
  };

  return <String, Object?>{
    'name': 'cron-runtime',
    'kind': 'cron-runtime',
    'now': formatCronInstant(now),
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'delivery',
        'label': '投递：返回假不消费时段且下 tick 重试、抛错不消费、交付成功才写运行戳与历史',
        'expect': <String, Object?>{
          'afterRefuse': afterRefuse,
          'afterAccept': afterAccept,
          'afterThrow': afterThrow,
          'isolated': isolation,
        },
      },
      <String, Object?>{
        'scenario': 'run-now',
        'label': 'runTaskNow：任务不存在 → not-found；投递不可用 → delivery-unavailable',
        'expect': <String, Object?>{
          'missing': await _guard(() async {
            final CronService empty = CronService(
              storage: MemoryCronStorage(),
              clock: () => now,
            );
            final CronRuntime runtime = CronRuntime(
              service: empty,
              deliver: (String id, String framing, CronTask task) async => true,
              options: CronRuntimeOptions(
                clock: () => now,
                tickSeconds: 1,
                firstTickDelay: Duration.zero,
              ),
            );
            runtime.dispose();
            try {
              await runtime.runTaskNow('ghost');
              return 'ran';
            } on CronException catch (error) {
              return error.code;
            }
          }),
          'unavailable': await _guard(() async {
            final CronService busy = CronService(
              storage: MemoryCronStorage(),
              clock: () => now,
            );
            busy.addDynamicTask(<String, Object?>{
              'id': 'busy',
              'prompt': '忙',
              'every': 600,
            });
            final CronRuntime runtime = CronRuntime(
              service: busy,
              deliver: (String id, String framing, CronTask task) async => false,
              options: CronRuntimeOptions(
                clock: () => now,
                tickSeconds: 1,
                firstTickDelay: Duration.zero,
              ),
            );
            runtime.dispose();
            try {
              await runtime.runTaskNow('busy');
              return 'ran';
            } on CronException catch (error) {
              return error.code;
            }
          }),
        },
      },
    ],
  };
}

String? formatCronIntervalTask(CronService service) =>
    formatCronInstant(service.findTask('boom')?.lastRunAt);

/// kind = cron-tools：五个工具的结果形状与错误码。
Future<Map<String, Object?>> _cronTools() async {
  final DateTime now = DateTime.parse('2026-03-09T10:00:00Z');
  final MemoryCronStorage storage = MemoryCronStorage();
  final CronService service =
      CronService(storage: storage, clock: () => now, onWarning: (String m) {});
  service.addDynamicTask(<String, Object?>{
    'id': 'list-me',
    'prompt': '列出来',
    'every': 600,
    'sessionId': 's1',
  });
  final CronRecordRef ref = service.allocateRecordRef(now);
  service.commitFire(ref: ref, taskId: 'list-me', slot: now, firedAt: now);
  service.finishRun(ref.id, ok: true, excerpt: '已完成');

  return <String, Object?>{
    'name': 'cron-tools',
    'kind': 'cron-tools',
    'now': formatCronInstant(now),
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'list',
        'label': 'cron_list：任务视图数组（规范 JSON 文本）',
        'expect': <String, Object?>{
          'json': jsonEncode(<Map<String, Object?>>[
            for (final CronTaskView view in service.listTasks()) view.toJson(),
          ]),
        },
      },
      <String, Object?>{
        'scenario': 'history',
        'label': 'cron_history：最新在前的记录数组，含状态与摘要',
        'expect': <String, Object?>{
          'json': jsonEncode(<Map<String, Object?>>[
            for (final CronRunRecord record in service.listHistory(limit: 5))
              record.toJson(),
          ]),
        },
      },
    ],
  };
}
