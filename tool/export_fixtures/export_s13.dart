// S13 Memory 召回 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法见 tool/export_fixtures/README.md。打分与词元化的语言相关行为
// （中文二元组、英文词、同分新→旧）全部导出结构化期望。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_foundation/conatus_foundation.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'recall-scoring': _recallScoring,
    'forget-and-govern': _forgetAndGovern,
    'json-backend-roundtrip': _jsonBackendRoundtrip,
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s13');
}

/// 召回打分：中文二元组 / 英文词 / 同分新→旧 / 多词交集计数。
Future<Map<String, Object?>> _recallScoring() async {
  final MemoryStore memory = MemoryStore();
  await memory.remember('用户喜欢京剧', tags: <String>{'偏好'});
  await memory.remember('用户喜欢喝咖啡', tags: <String>{'偏好'});
  await memory.remember('love coffee in the morning', tags: <String>{});

  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];
  cases.add(<String, Object?>{
    'label': '中文二元组命中',
    'query': '京剧',
    'expect': <String, Object?>{
      'texts': <String>[for (final MemoryEntry e in memory.recall('京剧')) e.text],
    },
  });
  cases.add(<String, Object?>{
    'label': '同分新→旧（「喜欢」命中两条）',
    'query': '喜欢',
    'expect': <String, Object?>{
      'texts': <String>[for (final MemoryEntry e in memory.recall('喜欢')) e.text],
    },
  });
  cases.add(<String, Object?>{
    'label': '英文按词命中',
    'query': 'coffee',
    'expect': <String, Object?>{
      'texts': <String>[for (final MemoryEntry e in memory.recall('coffee')) e.text],
    },
  });
  cases.add(<String, Object?>{
    'label': '交集计数：多词查询更高分在前',
    'query': '喜欢 咖啡',
    'expect': <String, Object?>{
      'texts': <String>[for (final MemoryEntry e in memory.recall('喜欢 咖啡')) e.text],
    },
  });
  cases.add(<String, Object?>{
    'label': '无命中与 limit 截断',
    'query': '不存在的词',
    'expect': <String, Object?>{
      'texts': <String>[for (final MemoryEntry e in memory.recall('不存在的词')) e.text],
      'limitOne': <String>[for (final MemoryEntry e in memory.recall('喜欢', limit: 1)) e.text],
    },
  });
  return <String, Object?>{
    'name': 'recall-scoring',
    'kind': 'recall-scoring',
    'cases': cases,
  };
}

/// 遗忘三式与容量治理。
Future<Map<String, Object?>> _forgetAndGovern() async {
  final MemoryStore memory = MemoryStore(maxEntries: 2);
  final MemoryEntry first = await memory.remember('第一条');
  await memory.remember('第二条');
  await memory.remember('第三条');
  final List<String> afterGovern =
      <String>[for (final MemoryEntry e in memory.entries) e.text];
  final bool forgot = await memory.forget(first.id);
  await memory.remember('第二条副本');
  final int byText = await memory.forgetByText('第二条副本');
  await memory.remember('含关键字的条目');
  final int matching = await memory.forgetMatching('关键');
  await memory.clear();
  return <String, Object?>{
    'name': 'forget-and-govern',
    'kind': 'forget-and-govern',
    'expect': <String, Object?>{
      'afterGovern': afterGovern,
      'forgot': forgot,
      'byText': byText,
      'matching': matching,
      'lengthAfterClear': memory.length,
    },
  };
}

/// JsonMemoryBackend 整表往返。
Future<Map<String, Object?>> _jsonBackendRoundtrip() async {
  final Directory dir = await Directory.systemTemp.createTemp('s13_fixture');
  try {
    final String file = '${dir.path}/memory.json';
    final MemoryStore memory = MemoryStore(backend: JsonMemoryBackend(file: File(file)));
    await memory.remember('用户喜欢京剧', tags: <String>{'偏好'});
    final MemoryStore reopened = MemoryStore(backend: JsonMemoryBackend(file: File(file)));
    await reopened.load();
    return <String, Object?>{
      'name': 'json-backend-roundtrip',
      'kind': 'json-backend-roundtrip',
      'expect': <String, Object?>{
        'reopenedTexts': <String>[for (final MemoryEntry e in reopened.entries) e.text],
        'reopenedTags': <List<String>>[
          for (final MemoryEntry e in reopened.entries)
            e.tags.toList()..sort(),
        ],
      },
    };
  } finally {
    await dir.delete(recursive: true);
  }
}
