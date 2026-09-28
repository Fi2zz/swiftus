// S19 Foundation 能力域（database / timer / time-context / logger / loader）导出器。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 用例自带输入，运行器据此驱动本地后端，产出同构投影后逐路径比对。
//
// 归一化（S19 专用）：
// - 临时根目录替换为 `<root>`；默认 home 目录形态只投影「以 database 结尾」；
// - 时刻不入投影（只投影是否随调用推进），`showTime` 关闭时行首无时间；
// - timer 只投影**计数与是否发生**，不投影具体间隔（时间不进 fixture）；
// - entry id 与上下文名按语义断言（存在/不存在、父子前缀），不比对全局序号。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_core/conatus_core.dart';
import 'package:conatus_foundation/conatus_foundation.dart';

const String _rootToken = '<root>';

late final Directory _dir;
String _root = '';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'database-hub': _databaseHub,
    'database-unit': _databaseUnit,
    'database-json': _databaseJson,
    'timer': _timer,
    'time-context': _timeContext,
    'logger': _logger,
    'loader': _loader,
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s19');
}

Directory _tempDir() {
  if (_root.isEmpty) {
    final Directory created = Directory.systemTemp.createTempSync('swiftus-s19');
    _root = created.resolveSymbolicLinksSync();
    _dir = Directory(_root);
  }
  return _dir;
}

String _dbCode(Object error) => error is DatabaseException
    ? error.code
    : error.runtimeType.toString();

String _loaderMessage(Object error) =>
    error is LoaderException ? error.message : error.runtimeType.toString();

/// 尽力执行并把异常收敛成 `{error: 码或消息}`。
Future<Object?> _guard(Future<Object?> Function() body) async {
  try {
    return await body();
  } catch (error) {
    return error;
  }
}

// ───────────────────────────── database · hub ─────────────────────────────

Future<Map<String, Object?>> _databaseHub() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  // 注册顺序、重名与空名。
  final Database dup = Database();
  await dup.register('json', JsonDatabaseBackend(dir: '${_tempDir().path}/a'));
  await dup.register('memory', StubBackend());
  final Object? duplicate = await _guard(() async {
    await dup.register('json', StubBackend());
    return 'registered';
  });
  final Object? emptyName = await _guard(() async {
    await dup.register('', StubBackend());
    return 'registered';
  });
  cases.add(<String, Object?>{
    'scenario': 'register',
    'label': '后端按注册顺序列出；重名与空名分别抛 duplicate-backend / invalid-backend',
    'expect': <String, Object?>{
      'backendNames': dup.backendNames,
      'duplicate': <String, Object?>{'error': _dbCode(duplicate!)},
      'emptyName': <String, Object?>{'error': _dbCode(emptyName!)},
      // 重名被拒后原后端仍在（旧撤销函数不得误删新后端，见 reload 场景）
      'namesAfterRejects': dup.backendNames,
    },
  });

  // 路由解析：显式 > default > 唯一 > 无解。
  final Database routes = Database(defaultBackend: 'json');
  await routes.register('json', JsonDatabaseBackend(dir: '${_tempDir().path}/b'));
  await routes.register('other', StubBackend());
  final String explicit = (await routes.open('u1', backend: 'other')).name;
  final String byDefault = (await routes.open('u2')).name;
  final Object? unknown = await _guard(() async {
    await routes.open('u3', backend: 'nope');
    return 'opened';
  });
  final Database ambiguous = Database();
  await ambiguous.register('x', StubBackend());
  await ambiguous.register('y', StubBackend());
  final Object? noBackend = await _guard(() async {
    await ambiguous.open('u');
    return 'opened';
  });
  final Database single = Database();
  await single.register('only', StubBackend());
  final String bySole = (await single.open('u')).name;
  cases.add(<String, Object?>{
    'scenario': 'route',
    'label': '后端路由：显式名 > 缺省名 > 唯一已注册；未注册与不唯一各抛对应码',
    'expect': <String, Object?>{
      'explicitBackendUnit': explicit,
      'defaultBackendUnit': byDefault,
      'unknownBackend': <String, Object?>{'error': _dbCode(unknown!)},
      'ambiguous': <String, Object?>{'error': _dbCode(noBackend!)},
      'soleRegisteredUnit': bySole,
    },
  });

  // 打开语义：已打开、空名、按打开顺序列出、get/close/closeAll。
  final Database opened = Database(defaultBackend: 'json');
  await opened.register('json', JsonDatabaseBackend(dir: '${_tempDir().path}/c'));
  final DatabaseUnit first = await opened.open('profile');
  await first.put('name', '助手');
  final DatabaseUnit second = await opened.open('scratch');
  final Object? alreadyOpen = await _guard(() async {
    await opened.open('profile');
    return 'opened';
  });
  final Object? emptyUnit = await _guard(() async {
    await opened.open('');
    return 'opened';
  });
  final List<String> unitsOpened = opened.units;
  final String? found = opened.get('profile')?.name;
  final String? missing = opened.get('ghost')?.name;
  final bool closedOne = opened.close('profile');
  final bool closedGhost = opened.close('ghost');
  await opened.closeAll();
  cases.add(<String, Object?>{
    'scenario': 'open',
    'label': 'open：已打开与空名被拒、单元按打开顺序列出、close 返回是否真的关闭、closeAll 全收',
    'expect': <String, Object?>{
      'unitsBeforeClose': unitsOpened,
      'alreadyOpen': <String, Object?>{'error': _dbCode(alreadyOpen!)},
      'emptyUnit': <String, Object?>{'error': _dbCode(emptyUnit!)},
      'getFound': found,
      'getMissing': missing,
      'closeOne': closedOne,
      'closeGhost': closedGhost,
      'unitClosedAfterHubClose': first.closed,
      'unitClosedAfterCloseAll': second.closed,
      'lengthAfterCloseAll': opened.length,
      'unitsAfterCloseAll': opened.units,
    },
  });

  // 旧撤销函数不得误删同名重注册的新后端。
  final Database swap = Database();
  final StubBackend firstBackend = StubBackend();
  final Disposer off = swap.register('b', firstBackend);
  off();
  await swap.register('b', StubBackend());
  off(); // 过期撤销：不得移除新后端
  final Object? stillThere = await _guard(() async {
    swap.backend('b');
    return 'present';
  });
  cases.add(<String, Object?>{
    'scenario': 'disposer',
    'label': '撤销函数幂等，且只撤销自己注册的那次（不误删同名重注册的后端）',
    'expect': <String, Object?>{
      'namesAfterSwap': swap.backendNames,
      'stillResolvable': stillThere,
    },
  });

  return <String, Object?>{
    'name': 'database-hub',
    'kind': 'database-hub',
    'root': _rootToken,
    'cases': cases,
  };
}

/// 内存后端替身：只记录最后一次 save 的整表。
class StubBackend implements DatabaseBackend {
  final Map<String, Map<String, Object?>> store = <String, Map<String, Object?>>{};
  int saves = 0;
  bool closed = false;

  @override
  Future<Map<String, Object?>> load(String unit) async =>
      Map<String, Object?>.of(store[unit] ?? const <String, Object?>{});

  @override
  Future<void> save(String unit, Map<String, Object?> records) async {
    saves += 1;
    store[unit] = Map<String, Object?>.of(records);
  }

  @override
  Future<void> deleteUnit(String unit) async => store.remove(unit);

  @override
  Future<void> close() async => closed = true;
}

// ───────────────────────────── database · 单元 ─────────────────────────────

Future<Map<String, Object?>> _databaseUnit() async {
  final Database hub = Database(defaultBackend: 'stub');
  await hub.register('stub', StubBackend());
  final DatabaseUnit unit = await hub.open('u');

  final List<Map<String, Object?>> changes = <Map<String, Object?>>[];
  final Disposer off = unit.onChange((DatabaseChange change) {
    changes.add(<String, Object?>{
      'unit': change.unit,
      'key': change.key,
      'kind': change.kind.name,
      // 「值是空的」在两端分别是 null 与 .null，故投影成布尔而不是原值。
      'valueIsNull': change.value == null,
    });
  });

  await unit.put('name', '助手');
  await unit.put('empty', null);
  await unit.put('name', '助手二代');
  final bool deleted = await unit.delete('name');
  final bool deletedMissing = await unit.delete('ghost');
  final Map<String, Object?> after = unit.entries();

  // 关闭后写入被拒；关闭清空监听器且幂等。
  unit.close();
  final Object? afterClose = await _guard(() async {
    await unit.put('x', 1);
    return 'written';
  });
  unit.close();
  off();
  // 关闭后再写：仍是 unit-closed（close 幂等，已关闭的单元不再接受写入）。
  await _guard(() async => unit.put('y', 2));

  return <String, Object?>{
    'name': 'database-unit',
    'kind': 'database-unit',
    'root': _rootToken,
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'write-chain',
        'label': '写入链：落盘成功后才更新内存并广播；删除不存在不落盘不广播',
        'input': <String, Object?>{
          'unit': 'u',
          'puts': <Object?>[
            <String, Object?>{'key': 'name', 'value': '助手'},
            <String, Object?>{'key': 'empty', 'value': null},
            <String, Object?>{'key': 'name', 'value': '助手二代'},
          ],
          'deletes': <String>['name', 'ghost'],
        },
        'expect': <String, Object?>{
          'changes': changes,
          'deleteExisting': deleted,
          'deleteMissing': deletedMissing,
          'entries': after,
          'keys': unit.keys,
          'length': unit.length,
          'hasEmptyValue': unit.has('empty'),
          'getMissingIsNull': unit.get('ghost') == null,
        },
      },
      <String, Object?>{
        'scenario': 'close',
        'label': 'close：幂等、清空监听器、关闭后写入抛 unit-closed、已从 hub 摘除',
        // 与 write-chain 同样的写入：先产生 4 条变更，再验证关闭行为（自描述）。
        'input': <String, Object?>{
          'unit': 'u',
          'puts': <Object?>[
            <String, Object?>{'key': 'name', 'value': '助手'},
            <String, Object?>{'key': 'empty', 'value': null},
            <String, Object?>{'key': 'name', 'value': '助手二代'},
          ],
          'deletes': <String>['name', 'ghost'],
        },
        'expect': <String, Object?>{
          'afterClose': <String, Object?>{'error': _dbCode(afterClose!)},
          'closed': unit.closed,
          'changesAfterClose': changes.length,
          'hubUnits': hub.units,
        },
      },
    ],
  };
}

// ───────────────────────────── database · JSON 后端 ─────────────────────────────

Future<Map<String, Object?>> _databaseJson() async {
  final String dir = '${_tempDir().path}/json';
  final JsonDatabaseBackend backend = JsonDatabaseBackend(dir: dir);
  final Directory unitDir = Directory('$dir');
  if (unitDir.existsSync()) unitDir.deleteSync(recursive: true);

  final Map<String, Object?> empty = await backend.load('missing');
  await backend.save('u1', <String, Object?>{'a': 1, 'b': null});
  final Map<String, Object?> reloaded = await backend.load('u1');
  final List<String> files = unitDir
      .listSync()
      .whereType<File>()
      .map((File f) => f.uri.pathSegments.last)
      .where((String n) => !n.contains('.tmp-'))
      .toList()
    ..sort();

  File('$dir/array.json').parent.createSync(recursive: true);
  File('$dir/array.json').writeAsStringSync('[1, 2]');
  final Object? malformed = await _guard(() async {
    await backend.load('array');
    return 'loaded';
  });
  final Object? slashUnit = await _guard(() async {
    await backend.load('a/b');
    return 'loaded';
  });
  final Object? emptyUnit = await _guard(() async {
    await backend.load('');
    return 'loaded';
  });
  await backend.deleteUnit('u1');
  final Map<String, Object?> afterDelete = await backend.load('u1');
  await backend.close();

  return <String, Object?>{
    'name': 'database-json',
    'kind': 'database-json',
    'root': _rootToken,
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'roundtrip',
        'label': '每单元一个人类可读 JSON 文件：不存在返回空表、整表往返、删除后清空',
        'input': <String, Object?>{
          'unit': 'u1',
          'records': <String, Object?>{'a': 1, 'b': null},
        },
        'expect': <String, Object?>{
          'loadMissing': empty,
          'reloaded': reloaded,
          'files': files,
          'loadAfterDelete': afterDelete,
        },
      },
      <String, Object?>{
        'scenario': 'malformed',
        'label': '非法载荷与非法单元名：非对象内容抛 malformed-medium，含分隔符或空名抛 invalid-unit',
        'input': <String, Object?>{'file': 'array.json', 'content': '[1, 2]'},
        'expect': <String, Object?>{
          'malformed': <String, Object?>{'error': _dbCode(malformed!)},
          'slashUnit': <String, Object?>{'error': _dbCode(slashUnit!)},
          'emptyUnit': <String, Object?>{'error': _dbCode(emptyUnit!)},
        },
      },
    ],
  };
}

// ───────────────────────────── timer ─────────────────────────────

Future<Map<String, Object?>> _timer() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  // timeout 触发一次；撤销后不再触发。
  final Context t1 = Context.root(name: 'timer/timeout');
  int fired = 0;
  final Disposer offTimeout = t1.timeout(() => fired += 1, const Duration(milliseconds: 40));
  await Future<void>.delayed(const Duration(milliseconds: 160));
  offTimeout();
  final int afterTimeout = fired;

  final Context t2 = Context.root(name: 'timer/timeout-cancel');
  int cancelledFired = 0;
  final Disposer off2 =
      t2.timeout(() => cancelledFired += 1, const Duration(milliseconds: 40));
  off2();
  await Future<void>.delayed(const Duration(milliseconds: 160));

  cases.add(<String, Object?>{
    'scenario': 'timeout',
    'label': 'timeout 触发一次；撤销（显式与随上下文释放）后不再触发',
    'expect': <String, Object?>{
      'firedOnce': afterTimeout,
      'firedAfterExplicitDisposer': cancelledFired,
    },
  });

  // interval 重复触发；随上下文释放停止。
  final Context t3 = Context.root(name: 'timer/interval');
  int ticks = 0;
  final Disposer off3 =
      t3.interval(() => ticks += 1, const Duration(milliseconds: 40));
  await Future<void>.delayed(const Duration(milliseconds: 220));
  t3.dispose();
  final int ticksAtDispose = ticks;
  await Future<void>.delayed(const Duration(milliseconds: 120));
  off3();
  cases.add(<String, Object?>{
    'scenario': 'interval',
    'label': 'interval 周期触发；上下文释放后停止（只断言「发生过多次」与「释放后不再增长」）',
    'expect': <String, Object?>{
      'tickedMultipleTimes': ticksAtDispose >= 2,
      'stoppedAfterDispose': ticks == ticksAtDispose,
    },
  });

  // sleep 正常完成；上下文提前释放则以错误结束。
  final Context t4 = Context.root(name: 'timer/sleep');
  bool slept = false;
  try {
    await t4.sleep(const Duration(milliseconds: 40))
        .timeout(const Duration(milliseconds: 500));
    slept = true;
  } catch (_) {
    // 到点前被中断即视为未睡成（只断言 sleep 是否正常完成）。
  }
  // 上下文在到点前被释放 → sleep 以错误结束（不悬挂）。**必须真的 dispose**：
  // 第一版忘了 dispose，sleep 自然跑完、用例什么也没验证（fixture 断言发现）。
  final Context t5 = Context.root(name: 'timer/sleep-cut');
  bool interrupted = false;
  final Future<void> pending = t5.sleep(const Duration(milliseconds: 3000));
  await Future<void>.delayed(const Duration(milliseconds: 60));
  t5.dispose();
  try {
    await pending;
  } catch (_) {
    interrupted = true;
  }
  cases.add(<String, Object?>{
    'scenario': 'sleep',
    'label': 'sleep 到点完成；上下文提前释放以错误结束（不悬挂）',
    'expect': <String, Object?>{
      'slept': slept,
      // 错误**类型**随语言而异（StateError / ContextDisposedError），
      // 只断言「以错误结束而不是悬挂」；具体类型由 Swift 侧单元测试锁定。
      'interrupted': interrupted,
    },
  });

  // 节流：窗口内多次调用合并；防抖：连续调用只执行一次。
  final Context t6 = Context.root(name: 'timer/throttle');
  int throttled = 0;
  final Throttled th = t6.throttle(() => throttled += 1, const Duration(milliseconds: 60));
  th();
  th();
  th();
  final int immediate = throttled;
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final int afterWindow = throttled;
  th();
  final int afterSecondCall = throttled;
  th.dispose();
  th();

  final Context t7 = Context.root(name: 'timer/debounce');
  int debounced = 0;
  final Debounced db = t7.debounce(() => debounced += 1, const Duration(milliseconds: 60));
  db();
  db();
  db();
  final int beforeWindow = debounced;
  await Future<void>.delayed(const Duration(milliseconds: 220));
  final int afterDebounce = debounced;
  db.dispose();
  db();
  await Future<void>.delayed(const Duration(milliseconds: 120));
  t6.dispose();
  t7.dispose();

  cases.add(<String, Object?>{
    'scenario': 'throttle-debounce',
    'label': 'throttle 首次立即执行、窗口内合并并补执行；debounce 连续调用只执行一次；dispose 后不再执行',
    'expect': <String, Object?>{
      'throttledImmediate': immediate,
      'throttledAfterWindow': afterWindow,
      'throttledSecondCallRuns': afterSecondCall == afterWindow + 1,
      'debouncedBeforeWindow': beforeWindow,
      'debouncedAfterWindow': afterDebounce,
      'debouncedOnce': afterDebounce == 1,
    },
  });

  return <String, Object?>{
    'name': 'timer',
    'kind': 'timer',
    'cases': cases,
  };
}

// ───────────────────────────── time-context ─────────────────────────────

/// 渲染一份锚点并投影。
///
/// `instant` 是**瞬时时刻**，`zone` 是「展示用时区名 + 该时刻自身的 UTC 偏移秒数」：
/// Dart 的 `DateTime` 自带时区，`zoneName` 只是**显示名覆盖**，偏移始终取时刻自身的
/// 时区偏移（两者相互独立，规格 S19 §3 已记）。把偏移显式写进输入，fixture 才与
/// 运行机器的本地时区无关。
Future<Map<String, Object?>> renderAnchor(
  String label,
  String instant,
  String? zoneName,
  int offsetSeconds,
) async {
  final Context ctx = Context.root();
  final SystemPrompt prompt = provideSystemPrompt(ctx);
  final DateTime at = DateTime.parse(instant);
  provideTimePrompt(
    ctx,
    prompt: prompt,
    clock: () => at,
    zoneName: zoneName,
  );
  final PromptAssembly assembled = prompt.assemble();
  final List<AssembledContext> contexts = assembled.contexts;
  final AssembledContext section = contexts.firstWhere(
    (AssembledContext c) => c.name == kTimeContextName,
  );
  ctx.dispose();
  return <String, Object?>{
    'label': label,
    'input': <String, Object?>{
      'instant': instant,
      'zoneName': zoneName,
      'offsetSeconds': offsetSeconds,
    },
    'expect': <String, Object?>{
      'name': section.name,
      // order 只参与排序（不外露）：断言它排在最前即锁住 -10 权重。
      'isFirstContext':
          contexts.isNotEmpty && contexts.first.name == kTimeContextName,
      'text': section.text,
    },
  };
}

Future<Map<String, Object?>> _timeContext() async {
  // Dart 侧只有 UTC 偏移能确定性地构造出来（`DateTime.parse` 带偏移会归一到 UTC，
  // `toLocal()` 又依赖运行机器的本地时区），故渲染类用例固定用 UTC 时刻；
  // **非零偏移下的日期 / 星期换算**由 Swift 侧单元测试用注入的偏移断言
  // （偏移是注入项，那一侧能表达任意值，规格 S19 §3 与实现注记已记这一分工）。
  return <String, Object?>{
    'name': 'time-context',
    'kind': 'time-context',
    'cases': <Object?>[
      await renderAnchor(
        'UTC 时刻 + 显示名覆盖：名字用覆盖值、偏移取时刻自身',
        '2026-03-09T00:00:00Z',
        'Asia/Shanghai',
        0,
      ),
      await renderAnchor(
        'UTC 时刻且无显示名覆盖：用时刻自身的时区缩写',
        '2026-12-31T23:30:00Z',
        null,
        0,
      ),
      await renderAnchor(
        'UTC 时刻 + IANA 名覆盖：名字透传',
        '2026-01-01T12:00:00Z',
        'Asia/Kolkata',
        0,
      ),
      await renderAnchor(
        'UTC 时刻跨年：日期与星期按时刻自身时区（UTC）取值',
        '2026-12-31T23:59:59Z',
        null,
        0,
      ),
      <String, Object?>{
        'label': '时区偏移格式化：正负号与补零（含半小时时区）',
        'input': <String, Object?>{'offsets': <int>[28800, -19800, 0, 1800]},
        'expect': <String, Object?>{
          'plus8': formatClockOffset(const Duration(hours: 8)),
          'minusHalf': formatClockOffset(
              const Duration(hours: -5, minutes: -30)),
          'utc': formatClockOffset(Duration.zero),
          'plusHalf': formatClockOffset(const Duration(minutes: 30)),
        },
      },
    ],
  };
}

// ───────────────────────────── logger ─────────────────────────────

Future<Map<String, Object?>> _logger() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];
  // 控制台行的 ISO 时刻是墙钟 → 归一为 <time>（时间不入 fixture，S19 §6）。
  List<String> _normalizedLines = const <String>[];

  // 级别过滤 + 环形上限 + 导出器增删。
  final LoggerService service = LoggerService(defaultName: 'root', level: LogLevel.warn)
    ..recentLimit = 3;
  final _Collector collector = _Collector();
  service.addExporter(collector);
  service.debug('d');
  service.info('i');
  service.warn('w');
  service.error('e');
  service.error('e2');
  service.error('e3');
  final int beforeRemove = collector.records.length;
  final bool removed = service.removeExporter(collector);
  final bool removedAgain = service.removeExporter(collector);
  service.error('after');
  cases.add(<String, Object?>{
    'scenario': 'level-ring',
    'label': '低于全局级别的日志被丢弃；最近日志按 recentLimit 环形保留；移除导出器后不再收到',
    'expect': <String, Object?>{
      'exportedBeforeRemove': beforeRemove,
      'exportedAfterRemove': collector.records.length,
      'removed': removed,
      'removedAgain': removedAgain,
      'recentMessages': service.recent.map((LogRecord r) => r.message).toList(),
      'recentCount': service.recent.length,
      'exporters': service.exporters.length,
    },
  });

  // 命名 logger：名字、级别、error 与堆栈随记录走。
  final LoggerService named = LoggerService();
  final _Collector named2 = _Collector();
  named.addExporter(named2);
  final Logger chat = named.logger('chat');
  chat.info('会话超时', 'timeout', StackTrace.fromString('frame-1\nframe-2'));
  named.error('根级');
  cases.add(<String, Object?>{
    'scenario': 'named',
    'label': '命名 logger 记录自己的名字与附加 error / 堆栈；服务方法用 defaultName',
    'expect': <String, Object?>{
      'records': <Object?>[
        for (final LogRecord record in named2.records)
          <String, Object?>{
            'level': record.level.name,
            'name': record.name,
            'message': record.message,
            'hasError': record.error != null,
            'hasStackTrace': record.stackTrace != null,
            'hasTime': record.time != DateTime.fromMillisecondsSinceEpoch(0),
          },
      ],
    },
  });

  // 控制台导出器：级别过滤、格式、error 追加、堆栈另起一行。
  final List<String> lines = <String>[];
  final ConsoleExporter console = ConsoleExporter(writer: lines.add);
  final LoggerService consoleService = LoggerService(level: LogLevel.debug)
    ..addExporter(console);
  consoleService.debug('d');
  consoleService.warn('w', 'boom');
  consoleService.error('e', 'bad', StackTrace.fromString('trace'));
  final ConsoleExporter filtered = ConsoleExporter(writer: lines.add, level: LogLevel.error);
  final LoggerService filterService = LoggerService(level: LogLevel.debug)
    ..addExporter(filtered);
  filterService.info('below');
  final ConsoleExporter timed = ConsoleExporter(
    writer: lines.add,
    showTime: true,
  );
  final LoggerService timedService = LoggerService(level: LogLevel.debug)
    ..addExporter(timed);
  timedService.info('has-time');
  // 全部写完后归一（避免把墙钟写进 fixture）：ISO 时刻前缀 → <time>。
  _normalizedLines = <String>[
    for (final String line in lines)
      RegExp(r'^\d{4}-\d{2}-\d{2}T[^ ]* ').hasMatch(line)
          ? line.replaceFirst(RegExp(r'^\d{4}-\d{2}-\d{2}T[^ ]*'), '<time>')
          : line,
  ];
  cases.add(<String, Object?>{
    'scenario': 'console',
    'label': '控制台导出器：[标签] 名字  消息；error 追加一个空格；堆栈另起一行；导出器自身级别过滤；showTime 只加时间前缀',
    'expect': <String, Object?>{
      // showTime 的 ISO 时刻是墙钟，逐次变化 → 归一为 <time> 后只比对形状。
      'lines': _normalizedLines,
      'showTimeAddsIsoPrefix':
          RegExp(r'^<time> \[I\] root  has-time$').hasMatch(_normalizedLines.last),
    },
  });

  return <String, Object?>{
    'name': 'logger',
    'kind': 'logger',
    'cases': cases,
  };
}

class _Collector implements LogExporter {
  final List<LogRecord> records = <LogRecord>[];

  @override
  void export(LogRecord record) => records.add(record);
}

// ───────────────────────────── loader ─────────────────────────────

Future<Map<String, Object?>> _loader() async {
  final List<String> log = <String>[];
  // 记号与辅助函数名无关（on:/off:），两端日志才可比。
  PluginFactory factory(String _) => (Context child, Object? config) {
    log.add('on:${config ?? '-'}');
    child.onDispose(() => log.add('off:${config ?? '-'}'));
  };

  // 注册表：空名被拒、同名覆盖、unregister 返回值。
  final Context ctx = Context.root();
  final Loader loader = provideLoader(ctx, plugins: <String, PluginFactory>{
    'a': factory('a'),
    'b': factory('b'),
  });
  final Object? emptyName = await _guard(() async {
    loader.register('', factory('x'));
    return 'registered';
  });
  loader.register('a', factory('a2'));
  final bool unregistered = loader.unregister('b');
  final bool unregisteredAgain = loader.unregister('b');
  cases_add('register', <String, Object?>{
    'label': '注册表：空名被拒、同名覆盖、unregister 返回是否真的移除',
    'expect': <String, Object?>{
      'emptyName': <String, Object?>{'error': _loaderMessage(emptyName!)},
      'names': loader.names,
      'hasA': loader.has('a'),
      'hasB': loader.has('b'),
      'unregistered': unregistered,
      'unregisteredAgain': unregisteredAgain,
    },
  });
  ctx.dispose();

  // 加载：子上下文生效、卸载时撤销、id 生成与父子前缀。
  final Context ctx2 = Context.root();
  final List<String> log2 = <String>[];
  final Loader loader2 = provideLoader(ctx2, plugins: <String, PluginFactory>{
    'a': (Context child, Object? config) {
      log2.add('on:${config ?? '-'}');
      child.onDispose(() => log2.add('off:${config ?? '-'}'));
    },
  });
  final String id1 = loader2.load(const LoaderEntry(name: 'a', config: 'x'));
  final String id2 = loader2.load(const LoaderEntry(name: 'a', config: 'y'));
  final String groupId = loader2.load(LoaderEntry(
    id: 'g',
    children: <LoaderEntry>[LoaderEntry(name: 'a', config: 'child')],
  ));
  final String childId = loader2.ids.firstWhere((String i) => i.startsWith('g:'));
  final Object? duplicateId = await _guard(() async {
    loader2.load(LoaderEntry(id: id1, name: 'a'));
    return 'loaded';
  });
  final Object? unknownPlugin = await _guard(() async {
    loader2.load(const LoaderEntry(id: 'nope', name: 'nope'));
    return 'loaded';
  });
  final bool isEmptyAfterUnknown = loader2.ids.contains('nope');
  final String? groupContext = loader2.contextOf('g')?.name;
  loader2.remove(id1);
  final List<String> afterRemove = List<String>.of(log2);
  final bool idsAfterRemove = loader2.ids.contains(id1);
  loader2.reload(childId);
  final int logLengthBeforeReload = log2.length;
  final Object? reloadUnknown = await _guard(() async {
    loader2.reload('ghost');
    return 'reloaded';
  });
  final Object? removeUnknown = await _guard(() async {
    loader2.remove('ghost');
    return 'removed';
  });
  cases_add('load', <String, Object?>{
    'label': 'load：id 生成与父子前缀、重复 id 与未注册插件被拒且不残留、分组不加载插件',
    'expect': <String, Object?>{
      'firstIdShape': RegExp(r'^entry-\d+$').hasMatch(id1),
      'secondIdShape': RegExp(r'^entry-\d+$').hasMatch(id2),
      'distinctIds': id1 != id2,
      'groupId': groupId,
      'childIdHasPrefix': childId.startsWith('g:'),
      'idsInLoadOrder': loader2.ids,
      'isEmptyFalse': !loader2.isEmpty,
      'duplicateId': <String, Object?>{'error': _loaderMessage(duplicateId!)},
      'unknownPlugin': <String, Object?>{'error': _loaderMessage(unknownPlugin!)},
      'unknownPluginResidue': isEmptyAfterUnknown,
      'groupHasNoContext': groupContext == null,
      'entryOfGroupIsGroup': loader2.entryOf('g')?.isGroup,
      'logAfterRemove': afterRemove,
      'idGoneAfterRemove': !idsAfterRemove,
      'reloadKeepsSingleContext': log2.length == logLengthBeforeReload + 1,
      'reloadUnknown': <String, Object?>{'error': _loaderMessage(reloadUnknown!)},
      'removeUnknown': <String, Object?>{'error': _loaderMessage(removeUnknown!)},
    },
  });

  // apply：先卸载全部（逆序）再按新树加载。
  final Context ctx3 = Context.root();
  final List<String> log3 = <String>[];
  final Loader loader3 = provideLoader(ctx3, plugins: <String, PluginFactory>{
    'a': (Context child, Object? config) {
      log3.add('on:${config ?? '-'}');
      child.onDispose(() => log3.add('off:${config ?? '-'}'));
    },
  });
  loader3.apply(<LoaderEntry>[
    const LoaderEntry(id: 'one', name: 'a', config: '1'),
    const LoaderEntry(id: 'two', name: 'a', config: '2'),
  ]);
  loader3.apply(<LoaderEntry>[const LoaderEntry(id: 'only', name: 'a', config: '3')]);
  cases_add('apply', <String, Object?>{
    'label': 'apply：全量替换——先卸载现有 entry 再按新树加载',
    'expect': <String, Object?>{
      'ids': loader3.ids,
      'isEmptyFalse': !loader3.isEmpty,
      // 拷快照：直接投影活列表会把后续 dispose 的日志也写进 fixture（本项目踩过）。
      'log': List<String>.of(log3),
    },
  });

  // JSON 往返 + 禁用项。
  final Context ctx4 = Context.root();
  final List<String> log4 = <String>[];
  final Loader loader4 = provideLoader(ctx4, plugins: <String, PluginFactory>{
    'a': (Context child, Object? config) {
      log4.add('on:${config ?? '-'}');
    },
  });
  loader4.applyJson(<Map<String, Object?>>[
    <String, Object?>{
      'id': 'top',
      'children': <Map<String, Object?>>[
        <String, Object?>{'name': 'a', 'config': 'nested'},
        <String, Object?>{'name': 'a', 'disabled': true},
      ],
    },
  ]);
  final String? disabledId = loader4.ids.length > 1 ? loader4.ids[1] : null;
  final bool disabledHasContext =
      disabledId == null ? false : loader4.contextOf(disabledId) != null;
  final Map<String, Object?> roundtrip = LoaderEntry.fromJson(
    loader4.entryOf('top')!.toJson(),
  ).toJson();
  cases_add('config-tree', <String, Object?>{
    'label': '配置树：分组递归子节点、禁用项不加载插件但仍登记、entry 可 JSON 往返',
    'expect': <String, Object?>{
      'ids': loader4.ids,
      'log': List<String>.of(log4),
      'disabledHasNoContext': !disabledHasContext,
      'groupRoundtrip': roundtrip,
    },
  });

  for (final Context c in <Context>[ctx2, ctx3, ctx4]) {
    c.dispose();
  }

  return <String, Object?>{
    'name': 'loader',
    'kind': 'loader',
    'root': _rootToken,
    'cases': cases,
  };
}

/// loader 的用例收集器（跨上下文复用一份列表）。
final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

/// 追加一个 loader 用例（抽出 label / expect）。
void cases_add(String scenario, Map<String, Object?> payload) {
  cases.add(<String, Object?>{
    'scenario': scenario,
    'label': payload.remove('label'),
    'expect': payload.remove('expect'),
  });
}
