// S8 调度语义 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 本文件的 fixture 统一形状：{name, kind, cases:[...]}；kind 分派见各 _fixture 函数。
// 时间一律以规范四位年份 RFC 3339 UTC 串表示（formatUtcInstant），语言中立。
// 导出侧校验：标记 expectError 的用例必须真的抛错，成功用例必须真的成功。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conatus_foundation/conatus_foundation.dart';
import 'package:conatus_schedule/conatus_schedule.dart';

final DateTime _now = DateTime.utc(2026, 8, 6, 12);

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, FutureOr<Map<String, Object?>> Function()> fixtures =
      <String, FutureOr<Map<String, Object?>> Function()>{
    'parse-at-offset': _parseAtOffset,
    'parse-at-local': _parseAtLocal,
    'create-records': _createRecords,
    'fold-events': _foldEvents,
    'every-occurrence': _everyOccurrence,
    'due-decision': _dueDecision,
    'framing': _framing,
    'service-flow': _serviceFlow,
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s8');
}

// ───────────────────────────── at 解析 ─────────────────────────────

/// kind = parse-at：input 为偏移串或本地对象；expect {instant} 或 {errorCode}。
Map<String, Object?> _parseAtOffset() => <String, Object?>{
      'name': 'parse-at-offset',
      'kind': 'parse-at',
      'cases': <Map<String, Object?>>[
        _atCase('2026-08-06T12:00:00+08:00'),
        _atCase('2026-08-06T12:00:00-05:30'),
        _atCase('2026-08-06T12:00:00.1Z'),
        _atCase('2026-08-06T12:00:00+00:00'),
        _atCase('2026-08-06T12:00:00'),
        _atCase('2026-08-06 12:00:00Z'),
        _atCase('2026-02-30T12:00:00Z'),
        _atCase('0000-08-06T12:00:00Z'),
        _atCase('2026-08-06T24:00:00Z'),
        _atCase('2026-08-06T12:00:00-00:00'),
        _atCase('2026-08-06T12:00:00+24:00'),
      ],
    };

Map<String, Object?> _parseAtLocal() => <String, Object?>{
      'name': 'parse-at-local',
      'kind': 'parse-at',
      'cases': <Map<String, Object?>>[
        _atCase(_localAt('2026-08-06', '12:00:00', 'UTC')),
        _atCase(_localAt('2026-08-06', '12:00:00', 'Asia/Shanghai')),
        _atCase(_localAt('2026-11-01', '01:30:00', 'America/New_York')),
        _atCase(_localAt('2026-03-08', '02:30:00', 'America/New_York')),
        _atCase(_localAt('2026-08-06', '12:00:00', 'CST')),
        _atCase(_localAt('2026-08-06', '12:00:00', 'GMT')),
        _atCase(_localAt('2026-08-06', '12:00:00', ' Asia/Shanghai')),
        _atCase(_localAt('2026-08-06', '12:00:00', 'Nope/Nowhere')),
        _atCase(<String, Object?>{'date': '2026-08-06', 'time': '12:00:00'}),
        _atCase(<String, Object?>{
          'date': '2026-8-6',
          'time': '12:00:00',
          'time_zone': 'UTC',
        }),
        _atCase(<String, Object?>{
          'date': '2026-02-30',
          'time': '12:00:00',
          'time_zone': 'UTC',
        }),
      ],
    };

Map<String, Object?> _localAt(String date, String time, String zone) =>
    <String, Object?>{'date': date, 'time': time, 'time_zone': zone};

Map<String, Object?> _atCase(Object? input) {
  try {
    final DateTime instant = resolveAtTarget(input);
    return <String, Object?>{
      'input': input,
      'expect': <String, Object?>{'instant': formatUtcInstant(instant)},
    };
  } on ScheduleInputException catch (error) {
    return <String, Object?>{
      'input': input,
      'expect': <String, Object?>{'errorCode': error.code},
    };
  }
}

// ───────────────────────────── 创建规则 ─────────────────────────────

/// kind = create-record：{selector:{afterSeconds?|at?|everySeconds?}, now} →
/// expect {record} 或 {errorCode}。prompt 固定「 提醒 」以覆盖 trim。
Map<String, Object?> _createRecords() => <String, Object?>{
      'name': 'create-records',
      'kind': 'create-record',
      'now': formatUtcInstant(_now),
      'cases': <Map<String, Object?>>[
        _createCase(afterSeconds: 600),
        _createCase(everySeconds: 300),
        _createCase(everySeconds: 299),
        _createCase(afterSeconds: 0),
        _createCase(at: '2026-08-06T13:00:00+01:00'),
        _createCase(at: '2026-08-06T12:00:00.000Z'),
        _createCase(afterSeconds: 60, prompt: '   '),
      ],
    };

Map<String, Object?> _createCase({
  int? afterSeconds,
  Object? at,
  int? everySeconds,
  String prompt = ' 提醒 ',
}) {
  try {
    final ScheduleRecord record = at != null
        ? createAtRecord(id: 'schedule-1', prompt: prompt, at: at, now: _now)
        : afterSeconds != null
            ? createAfterRecord(
                id: 'schedule-1',
                prompt: prompt,
                afterSeconds: afterSeconds,
                now: _now,
              )
            : createEveryRecord(
                id: 'schedule-1',
                prompt: prompt,
                everySeconds: everySeconds,
                now: _now,
              );
    return <String, Object?>{
      'selector': _selector(afterSeconds, at, everySeconds),
      'prompt': prompt,
      'expect': <String, Object?>{'record': record.toJson()},
    };
  } on ScheduleInputException catch (error) {
    return <String, Object?>{
      'selector': _selector(afterSeconds, at, everySeconds),
      'prompt': prompt,
      'expect': <String, Object?>{'errorCode': error.code},
    };
  }
}

Map<String, Object?> _selector(int? afterSeconds, Object? at, int? everySeconds) =>
    <String, Object?>{
      if (afterSeconds != null) 'afterSeconds': afterSeconds,
      if (at != null) 'at': at,
      if (everySeconds != null) 'everySeconds': everySeconds,
    };

// ───────────────────────────── 折叠 ─────────────────────────────

/// kind = fold：events 为 schedule/change 载荷序列；expect {active, seenIds}
/// 或 {corrupt: 违规消息}。
Map<String, Object?> _foldEvents() {
  final Map<String, Object?> createOne = _createPayload(_record('schedule-1',
      kind: 'after', afterSeconds: 600, scheduledAt: '2026-08-06T12:10:00.000Z'));
  final Map<String, Object?> createEvery = _createPayload(_record('schedule-2',
      kind: 'every', everySeconds: 300, scheduledAt: '2026-08-06T12:05:00.000Z'));
  return <String, Object?>{
    'name': 'fold-events',
    'kind': 'fold',
    'cases': <Map<String, Object?>>[
      _foldCase('创建后活动', <Map<String, Object?>>[createOne]),
      _foldCase('创建删除后空,seenIds 保留', <Map<String, Object?>>[
        createOne,
        <String, Object?>{'version': 1, 'operation': 'delete', 'id': 'schedule-1'},
      ]),
      _foldCase('every 派发推进目标', <Map<String, Object?>>[
        createEvery,
        <String, Object?>{
          'version': 1,
          'operation': 'dispatch',
          'id': 'schedule-2',
          'acceptedAt': '2026-08-06T12:07:00.000Z',
        },
      ]),
      _foldCase('id 复用抛 corrupt', <Map<String, Object?>>[createOne, createOne]),
      _foldCase('删除非活动 id 抛 corrupt', <Map<String, Object?>>[
        <String, Object?>{'version': 1, 'operation': 'delete', 'id': 'ghost'},
      ]),
      _foldCase('一次性派发带 acceptedAt 抛 corrupt', <Map<String, Object?>>[
        createOne,
        <String, Object?>{
          'version': 1,
          'operation': 'dispatch',
          'id': 'schedule-1',
          'acceptedAt': '2026-08-06T12:10:00.000Z',
        },
      ]),
      _foldCase('every 派发缺 acceptedAt 抛 corrupt', <Map<String, Object?>>[
        createEvery,
        <String, Object?>{
          'version': 1,
          'operation': 'dispatch',
          'id': 'schedule-2',
        },
      ]),
      _foldCase('未知版本抛 corrupt', <Map<String, Object?>>[
        <String, Object?>{'version': 2, 'operation': 'delete', 'id': 'x'},
      ]),
    ],
  };
}

Map<String, Object?> _foldCase(String label, List<Map<String, Object?>> changes) {
  final Session session = Session(id: 's1');
  for (final Map<String, Object?> change in changes) {
    session.append(kScheduleChangeEvent, data: change);
  }
  try {
    final ScheduleFold folded = foldScheduleEvents(session.ownEvents);
    return <String, Object?>{
      'label': label,
      'events': changes,
      'expect': <String, Object?>{
        'active': <Object?>[for (final ScheduleRecord r in folded.active) r.toJson()],
        'seenIds': folded.seenIds,
      },
    };
  } on ScheduleLogException catch (error) {
    return <String, Object?>{
      'label': label,
      'events': changes,
      'expect': <String, Object?>{'corrupt': error.message},
    };
  }
}

Map<String, Object?> _record(
  String id, {
  required String kind,
  required String scheduledAt,
  int? afterSeconds,
  int? everySeconds,
  String prompt = '到点了',
}) =>
    <String, Object?>{
      'id': id,
      'kind': kind,
      'prompt': prompt,
      if (afterSeconds != null) 'afterSeconds': afterSeconds,
      if (everySeconds != null) 'everySeconds': everySeconds,
      'scheduledAt': scheduledAt,
    };

Map<String, Object?> _createPayload(Map<String, Object?> record) =>
    <String, Object?>{'version': 1, 'operation': 'create', 'schedule': record};

// ───────────────────────────── every 算术 ─────────────────────────────

/// kind = every-occurrence：{scheduledAt, everySeconds, acceptedAt} →
/// expect {occurrenceAt, nextScheduledAt?} 或 {corrupt}。
Map<String, Object?> _everyOccurrence() => <String, Object?>{
      'name': 'every-occurrence',
      'kind': 'every-occurrence',
      'cases': <Map<String, Object?>>[
        _occurrenceCase('2026-08-06T12:00:00.000Z', 300, '2026-08-06T12:00:00.000Z'),
        _occurrenceCase('2026-08-06T12:00:00.000Z', 300, '2026-08-06T12:07:00.000Z'),
        _occurrenceCase('2026-08-06T12:00:00.000Z', 300, '2026-08-06T11:59:00.000Z'),
      ],
    };

Map<String, Object?> _occurrenceCase(
  String scheduledAt,
  int everySeconds,
  String acceptedAt,
) {
  final Map<String, Object?> input = <String, Object?>{
    'scheduledAt': scheduledAt,
    'everySeconds': everySeconds,
    'acceptedAt': acceptedAt,
  };
  final ScheduleRecord record = ScheduleRecord(
    id: 'schedule-1',
    kind: ScheduleKind.every,
    prompt: '检查',
    everySeconds: everySeconds,
    scheduledAt: DateTime.parse(scheduledAt),
  );
  try {
    final EveryOccurrence occurrence =
        resolveEveryOccurrence(record, DateTime.parse(acceptedAt));
    return <String, Object?>{
      'input': input,
      'expect': <String, Object?>{
        'occurrenceAt': formatUtcInstant(occurrence.occurrenceAt),
        'nextScheduledAt': occurrence.nextScheduledAt == null
            ? null
            : formatUtcInstant(occurrence.nextScheduledAt!),
      },
    };
  } on ScheduleLogException catch (error) {
    return <String, Object?>{
      'input': input,
      'expect': <String, Object?>{'corrupt': error.message},
    };
  }
}

// ───────────────────────────── 到期决策 ─────────────────────────────

/// kind = due-decision：{active:[record...], now} →
/// expect {type: wait, target?} / {type: one-shot, id} /
/// {type: every-batch, items:[{id, occurrenceAt}], acceptedAt}。
Map<String, Object?> _dueDecision() => <String, Object?>{
      'name': 'due-decision',
      'kind': 'due-decision',
      'cases': <Map<String, Object?>>[
        _decisionCase('一次性到期优先', <Map<String, Object?>>[
          _record('schedule-1', kind: 'at', scheduledAt: '2026-08-06T11:00:00.000Z'),
          _record('schedule-2',
              kind: 'every', everySeconds: 300, scheduledAt: '2026-08-06T11:00:00.000Z'),
        ], '2026-08-06T12:00:00.000Z'),
        _decisionCase('every 批次共用决策时点', <Map<String, Object?>>[
          _record('schedule-1',
              kind: 'every', everySeconds: 300, scheduledAt: '2026-08-06T11:00:00.000Z'),
          _record('schedule-2',
              kind: 'every', everySeconds: 600, scheduledAt: '2026-08-06T11:30:00.000Z'),
        ], '2026-08-06T12:00:00.000Z'),
        _decisionCase('无到期取最小未来目标', <Map<String, Object?>>[
          _record('schedule-1', kind: 'at', scheduledAt: '2026-08-06T13:00:00.000Z'),
          _record('schedule-2', kind: 'at', scheduledAt: '2026-08-06T12:30:00.000Z'),
        ], '2026-08-06T12:00:00.000Z'),
        _decisionCase('无活动保持静默', const <Map<String, Object?>>[],
            '2026-08-06T12:00:00.000Z'),
      ],
    };

Map<String, Object?> _decisionCase(
  String label,
  List<Map<String, Object?>> records,
  String now,
) {
  final ScheduleFold folded = foldScheduleEvents(<SessionEvent>[
    for (final Map<String, Object?> record in records)
      SessionEvent.create(
        sessionId: 's1',
        type: kScheduleChangeEvent,
        seq: 0,
        data: _createPayload(record),
      ),
  ]);
  final DueDecision decision = dueDecision(folded, DateTime.parse(now));
  return <String, Object?>{
    'label': label,
    'active': records,
    'now': now,
    'expect': _decisionJson(decision),
  };
}

Map<String, Object?> _decisionJson(DueDecision decision) => switch (decision) {
      ScheduleOneShotDue(:final ScheduleRecord record) =>
        <String, Object?>{'type': 'one-shot', 'id': record.id},
      ScheduleEveryBatchDue(
        :final List<ScheduleDue> reminders,
        :final DateTime acceptedAt
      ) =>
        <String, Object?>{
          'type': 'every-batch',
          'acceptedAt': formatUtcInstant(acceptedAt),
          'items': <Object?>[
            for (final ScheduleDue due in reminders)
              <String, Object?>{
                'id': due.record.id,
                'occurrenceAt': formatUtcInstant(due.occurrenceAt),
              },
          ],
        },
      ScheduleWait(:final DateTime? target) => <String, Object?>{
          'type': 'wait',
          'target': target == null ? null : formatUtcInstant(target),
        },
    };

// ───────────────────────────── framing 快照 ─────────────────────────────

/// kind = framing：{record} 或 {records:[...]} → expect {text}（逐字符快照）。
Map<String, Object?> _framing() {
  final ScheduleRecord oneShot = ScheduleRecord(
    id: 'schedule-1',
    kind: ScheduleKind.at,
    prompt: '提醒「带引号」与\n换行',
    scheduledAt: DateTime.parse('2026-08-06T12:30:00.000Z'),
  );
  final List<ScheduleDue> batch = <ScheduleDue>[
    ScheduleDue(
      record: ScheduleRecord(
        id: 'schedule-1',
        kind: ScheduleKind.every,
        prompt: '检查构建',
        everySeconds: 300,
        scheduledAt: DateTime.parse('2026-08-06T11:55:00.000Z'),
      ),
      occurrenceAt: DateTime.parse('2026-08-06T11:55:00.000Z'),
    ),
  ];
  return <String, Object?>{
    'name': 'framing',
    'kind': 'framing',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'label': '一次性 framing(含中文/引号/换行转义)',
        'record': oneShot.toJson(),
        'expect': <String, Object?>{'text': renderReminderFraming(oneShot)},
      },
      <String, Object?>{
        'label': '批次 framing',
        'records': <Object?>[for (final ScheduleDue d in batch) d.record.toJson()],
        'occurrenceAts': <Object?>[formatUtcInstant(batch.first.occurrenceAt)],
        'expect': <String, Object?>{'text': renderReminderBatchFraming(batch)},
      },
      <String, Object?>{
        'label': '等待决策无交付文本',
        'expect': <String, Object?>{'text': renderDueFraming(ScheduleWait(null))},
      },
    ],
  };
}

// ───────────────────────────── 服务端到端 ─────────────────────────────

/// kind = service-flow：固定时钟注入的 create/list/delete 与 fork 不继承。
/// expect 给出每步结果与最终日志（schedule/change 载荷序列）。
Future<Map<String, Object?>> _serviceFlow() async {
  final Session session = Session(id: 's1');
  final SessionSchedule schedule = SessionSchedule(
    session: session,
    clock: () => _now,
  );
  final ScheduleView created =
      await schedule.create(prompt: ' 到点了 ', afterSeconds: 600);
  final List<ScheduleView> listed = await schedule.list();
  final ScheduleDeleteResult deleted = await schedule.delete('schedule-1');
  final List<ScheduleView> afterDelete = await schedule.list();
  final Session forked = session.fork(id: 's1-fork-1');
  final List<ScheduleRecord> forkedActive =
      foldScheduleEvents(forked.ownEvents).active;
  return <String, Object?>{
    'name': 'service-flow',
    'kind': 'service-flow',
    'now': formatUtcInstant(_now),
    'expect': <String, Object?>{
      'created': created.toJson(),
      'listed': <Object?>[for (final ScheduleView view in listed) view.toJson()],
      'deleted': deleted.toJson(),
      'afterDelete': <Object?>[for (final ScheduleView view in afterDelete) view.toJson()],
      'forkedActiveEmpty': forkedActive.isEmpty,
      'log': <Object?>[
        for (final SessionEvent event in session.ownEvents)
          <String, Object?>{'seq': event.seq, 'type': event.type, 'data': event.data},
      ],
    },
  };
}
