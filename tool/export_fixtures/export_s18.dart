// S18 Foundation 能力域（fs / shell）golden fixtures 导出器。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 用例自带输入与步骤脚本，运行器据此驱动本地后端，产出同构投影后逐路径比对。
//
// 归一化（S18 专用）：
// - 临时根目录一律替换为 `<root>`（路径类断言与机器/用户无关）；
// - 版本令牌（新鲜度）不比对具体串，只断言「稳定 / 变化」这类语义
//   （格式由实现自定，跨实现不可比）；
// - 被信号杀死的进程退出码随平台而异，只断言「是否为负数」。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_foundation/conatus_foundation.dart';

const String _rootToken = '<root>';

late final Directory _dir;
String _root = '';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'fs-paths': _fsPaths,
    'fs-ops': _fsOps,
    'shell-resolve': _shellResolve,
    'shell-run': _shellRun,
    'shell-start': _shellStart,
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s18');
}

/// 路径投影：临时根替换为 `<root>`，分隔符统一为 `/`。
String _path(String raw) =>
    raw.replaceAll(_root, _rootToken).replaceAll(Platform.pathSeparator, '/');

/// 临时目录（惰性创建一次，整轮共用）。
Directory _tempDir() {
  if (_root.isEmpty) {
    // 用真实路径做基准：targetKey 走 realpath，投影替换才对得上。
    final Directory created = Directory.systemTemp.createTempSync('swiftus-s18');
    _root = created.resolveSymbolicLinksSync();
    _dir = Directory(_root);
  }
  return _dir;
}

String _write(String name, String content) {
  final File file = File('${_tempDir().path}/$name');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file.path;
}

String _errorCode(Object error) =>
    error is FsError ? error.code.code : error.runtimeType.toString();

Future<Object?> _guard(Future<Object?> Function() body) async {
  try {
    return await body();
  } catch (error) {
    return <String, Object?>{'error': _errorCode(error)};
  }
}

Map<String, Object?> _error(Object error) =>
    <String, Object?>{'error': _errorCode(error)};

// ───────────────────────────── 路径与身份 ─────────────────────────────

/// kind = fs-paths：规范化 / 身份稳定性 / contains / lstat。
Future<Map<String, Object?>> _fsPaths() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  final File existing = File(_write('paths/existing.txt', 'hello'));
  final String aliasPath = '${_tempDir().path}/paths/alias.txt';
  Link(aliasPath).createSync(existing.path);

  Future<Map<String, Object?>> resolveCase(
    String label,
    String path, {
    String? cwd,
  }) async {
    try {
      final FsTarget target = await fs.resolve(path, cwd: cwd);
      return <String, Object?>{
        'label': label,
        'expect': <String, Object?>{
          'displayPath': _path(target.displayPath),
        },
      };
    } catch (error) {
      return <String, Object?>{
        'label': label,
        'expect': <String, Object?>{'error': _errorCode(error)},
      };
    }
  }

  final FsTarget existingTarget = await fs.resolve(existing.path);
  final FsTarget aliasTarget = await fs.resolve(aliasPath);
  final FsTarget viaDot = await fs.resolve('${_tempDir().path}/paths/./existing.txt');
  final FsTarget viaDotDot =
      await fs.resolve('${_tempDir().path}/paths/sub/../existing.txt');
  final FsTarget subdir = await fs.resolve('${_tempDir().path}/paths');

  // 不存在的目标：父目录真实路径 + basename；父目录随后被创建，键仍稳定。
  const String missingRelative = 'paths/fresh-dir/fresh.txt';
  final FsTarget beforeDir =
      await fs.resolve('${_tempDir().path}/$missingRelative');
  Directory('${_tempDir().path}/paths/fresh-dir').createSync();
  final FsTarget afterDir = await fs.resolve('${_tempDir().path}/$missingRelative');
  final FsTarget deepMissing =
      await fs.resolve('${_tempDir().path}/paths/never/sub/file.txt');

  // lstat 不跟随最后一段符号链接。
  final FsPathInfo? linkInfo = await fs.lstat(aliasPath);
  final FsInfo? linkStat = await fs.stat(aliasTarget);

  return <String, Object?>{
    'name': 'fs-paths',
    'kind': 'fs-paths',
    'root': _rootToken,
    'cases': <Object?>[
      await resolveCase('绝对路径原样保留', existing.path),
      await resolveCase('相对路径以 cwd 为基准', 'paths/existing.txt'),
      await resolveCase('cwd 覆盖实例基准', 'existing.txt',
          cwd: '${_tempDir().path}/paths'),
      await resolveCase('点段与父段被消解', '${_tempDir().path}/paths/sub/.././existing.txt'),
      await resolveCase('尾部分隔符被消解', '${_tempDir().path}/paths/'),
      await resolveCase('反斜杠也作分隔符', '${_tempDir().path}\\paths\\existing.txt'),
      await resolveCase('空路径抛 notFound', '   '),
      <String, Object?>{
        'label': '同一文件的别名共享身份键（符号链接 / 点段 / 父段）',
        'expect': <String, Object?>{
          'aliasKeyEqualsDirect': aliasTarget.targetKey == existingTarget.targetKey,
          'dotKeyEqualsDirect': viaDot.targetKey == existingTarget.targetKey,
          'dotDotKeyEqualsDirect': viaDotDot.targetKey == existingTarget.targetKey,
          'aliasDisplayDiffers': aliasTarget.displayPath != existingTarget.displayPath,
        },
      },
      <String, Object?>{
        'label': '不存在的目标：父目录已存在时键为「真实父路径 + basename」，父目录缺失时退回展示路径',
        'expect': <String, Object?>{
          // 父目录已存在：真实父路径 + basename（根已是真实路径，故与展示路径同形）
          'parentExists_keyEqualsDisplayPath':
              afterDir.targetKey == afterDir.displayPath,
          // 父目录缺失：兜底为展示路径
          'parentMissing_keyEqualsDisplayPath':
              deepMissing.targetKey == deepMissing.displayPath,
          // 父目录**事后**创建：键从展示路径变为真实父路径 + basename（Dart 实际行为）
          'keyChangesWhenParentAppears': beforeDir.targetKey != afterDir.targetKey,
        },
      },
      <String, Object?>{
        'label': 'contains：自身与同一文件（别名）算包含、子孙算包含',
        'expect': <String, Object?>{
          'self': fs.contains(subdir, subdir),
          'child': fs.contains(subdir, existingTarget),
          'sameFileViaAlias': fs.contains(existingTarget, aliasTarget),
          'parentIsNotChild': fs.contains(existingTarget, subdir),
        },
      },
      <String, Object?>{
        'label': 'processPath 与 fileUrl 形态',
        'expect': <String, Object?>{
          'processPath': _path(fs.processPath(existingTarget)),
          'fileUrlStartsWithFile': fs.fileUrl(existingTarget).startsWith('file://'),
        },
      },
      <String, Object?>{
        'label': 'lstat 不跟随最后一段符号链接（stat 则跟随）',
        'expect': <String, Object?>{
          'lstatType': linkInfo?.type.name,
          'statType': linkStat?.type.name,
          'lstatSize': linkInfo?.size,
        },
      },
    ],
  };
}

// ───────────────────────────── 文件操作 ─────────────────────────────

/// kind = fs-ops：stat / readText / writeText / editText / listDir / remove。
Future<Map<String, Object?>> _fsOps() async {
  return <String, Object?>{
    'name': 'fs-ops',
    'kind': 'fs-ops',
    'root': _rootToken,
    'cases': <Map<String, Object?>>[
      await _readCase(),
      await _writeCase(),
      await _writeGuardCase(),
      await _editCase(),
      await _listCase(),
      await _removeCase(),
    ],
  };
}

/// stat + readText 的错误码矩阵。
Future<Map<String, Object?>> _readCase() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  final String text = _write('ops/read.txt', '你好\nworld\n');
  final String binary = '${_tempDir().path}/ops/binary.bin';
  File(binary).writeAsBytesSync(<int>[0xff, 0xfe, 0x00]);
  final String subdir = _write('ops/sub/inner.txt', 'x');

  Future<Map<String, Object?>> probe(String path) async {
    final FsTarget target = await fs.resolve(path);
    final FsInfo? info = await fs.stat(target);
    final Object? text2 = await _guard(() async => await fs.readText(target));
    return <String, Object?>{
      'path': _path(path),
      'exists': info != null,
      'type': info?.type.name,
      'size': info?.size,
      'read': text2,
    };
  }

  return <String, Object?>{
    'scenario': 'read',
    'label': 'stat 元数据 + readText 的类型化错误码',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'ops/read.txt', 'content': '你好\nworld\n'},
        <String, Object?>{'name': 'ops/binary.bin', 'content': '<binary>'},
        <String, Object?>{'name': 'ops/sub/inner.txt', 'content': 'x'},
      ],
    },
    'expect': <String, Object?>{
      'probes': <Object?>[
        await probe(text),
        await probe(binary),
        await probe('${_tempDir().path}/ops/sub'),
        await probe('${_tempDir().path}/ops/ghost.txt'),
      ],
      'textFile': await _guard(() async {
        final FsTarget target = await fs.resolve(text);
        return await fs.readText(target);
      }),
      'subdirKept': _path(subdir).endsWith('/ops/sub/inner.txt'),
    },
  };
}

/// writeText：新建 / 覆盖 / 原子发布。
Future<Map<String, Object?>> _writeCase() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  final FsTarget fresh = await fs.resolve('${_tempDir().path}/ops/new/deep/file.txt');
  final FsWriteOutcome created = await fs.writeText(fresh, '第一版');
  final FsWriteOutcome updated = await fs.writeText(fresh, '第二版');
  final FsTarget dir = await fs.resolve('${_tempDir().path}/ops');
  Object? onDirectory = await _guard(() async => await fs.writeText(dir, 'x'));

  return <String, Object?>{
    'scenario': 'write',
    'label': 'writeText：父目录递归创建、operation 区分新建/覆盖、before 为旧内容',
    'input': <String, Object?>{'target': 'ops/new/deep/file.txt'},
    'expect': <String, Object?>{
      'created': <String, Object?>{
        'operation': created.operation.name,
        'before': created.before,
        'after': created.after,
        'contentOnDisk': File(fresh.targetKey).readAsStringSync(),
        'versionChanged': created.version != updated.version,
        'tempLeftovers': Directory(fresh.targetKey).parent
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.contains('.tmp-'))
            .length,
      },
      'updated': <String, Object?>{
        'operation': updated.operation.name,
        'before': updated.before,
        'after': updated.after,
        'contentOnDisk': File(fresh.targetKey).readAsStringSync(),
      },
      'writeToDirectory': onDirectory,
    },
  };
}

/// 写入守卫：create-if-absent / replace-if-version。
Future<Map<String, Object?>> _writeGuardCase() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  final FsTarget target = await fs.resolve('${_tempDir().path}/ops/guard.txt');
  final FsWriteOutcome first = await fs.writeText(target, 'v1');
  final Object? createIfAbsent = await _guard(
      () async => await fs.writeText(target, 'v2', expected: const FsCreateIfAbsent()));
  final Object? staleVersion = await _guard(() async => await fs.writeText(
      target, 'v3', expected: FsReplaceIfVersion('stale-token')));
  final FsWriteOutcome replaced = await fs.writeText(
      target, 'v4', expected: FsReplaceIfVersion(first.version));
  final FsTarget absent = await fs.resolve('${_tempDir().path}/ops/guard-absent.txt');
  final Object? absentVersion = await _guard(() async => await fs.writeText(
      absent, 'v5', expected: FsReplaceIfVersion('whatever')));
  return <String, Object?>{
    'scenario': 'guard',
    'label': '写入守卫：已存在拒无条件覆盖、版本不符拒替换、版本相符放行',
    'input': <String, Object?>{'target': 'ops/guard.txt'},
    'expect': <String, Object?>{
      'createIfAbsentOnExisting': createIfAbsent,
      'staleVersion': staleVersion,
      'replaceWithCurrentVersion': <String, Object?>{
        'operation': replaced.operation.name,
        'after': replaced.after,
        'contentOnDisk': File(target.targetKey).readAsStringSync(),
      },
      'replaceOnMissing': absentVersion,
    },
  };
}

/// editText：命中 / 未命中 / 歧义 / replaceAll / 版本守卫。
Future<Map<String, Object?>> _editCase() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  final FsTarget target = await fs.resolve('${_tempDir().path}/ops/edit.txt');
  await fs.writeText(target, 'alpha\nbeta\nalpha\n');
  final Object? notFound = await _guard(() async =>
      await fs.editText(target, const FsEditRequest(oldString: 'gamma', newString: 'x')));
  final Object? ambiguous = await _guard(() async =>
      await fs.editText(target, const FsEditRequest(oldString: 'alpha', newString: 'x')));
  final FsEditOutcome all = await fs.editText(
      target, const FsEditRequest(oldString: 'alpha', newString: 'A', replaceAll: true));
  final Object? staleEdit = await _guard(() async => await fs.editText(
      target, const FsEditRequest(oldString: 'beta', newString: 'z'),
      expectedVersion: 'stale-token'));
  final FsEditOutcome fresh = await fs.editText(
      target, const FsEditRequest(oldString: 'beta', newString: 'B'),
      expectedVersion: all.version);
  final FsTarget absent = await fs.resolve('${_tempDir().path}/ops/edit-absent.txt');
  final Object? editMissing = await _guard(() async => await fs.editText(
      absent, const FsEditRequest(oldString: 'a', newString: 'b')));

  return <String, Object?>{
    'scenario': 'edit',
    'label': 'editText：未命中 / 歧义 / replaceAll / 版本守卫 / 目标缺失',
    'input': <String, Object?>{'target': 'ops/edit.txt', 'content': 'alpha\nbeta\nalpha\n'},
    'expect': <String, Object?>{
      'notFound': notFound,
      'ambiguous': ambiguous,
      'replaceAll': <String, Object?>{
        'before': all.before,
        'after': all.after,
        'contentOnDisk': File(target.targetKey).readAsStringSync(),
      },
      'staleVersion': staleEdit,
      'freshVersion': <String, Object?>{
        'before': fresh.before,
        'after': fresh.after,
        'contentOnDisk': File(target.targetKey).readAsStringSync(),
      },
      'missingTarget': editMissing,
    },
  };
}

/// listDir：稳定排序、类型与 size、不读内容。
Future<Map<String, Object?>> _listCase() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  _write('ops/list/b.txt', 'bb');
  _write('ops/list/a.txt', 'a');
  _write('ops/list/nested/c.txt', 'ccc');
  final FsTarget dir = await fs.resolve('${_tempDir().path}/ops/list');
  final List<FsDirEntry> entries = await fs.listDir(dir);
  final FsTarget file = await fs.resolve('${_tempDir().path}/ops/list/a.txt');
  final Object? onFile = await _guard(() async => await fs.listDir(file));

  return <String, Object?>{
    'scenario': 'list',
    'label': 'listDir：按名排序、只给元数据、非目录报 notDirectory',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'ops/list/b.txt', 'content': 'bb'},
        <String, Object?>{'name': 'ops/list/a.txt', 'content': 'a'},
        <String, Object?>{'name': 'ops/list/nested/c.txt', 'content': 'ccc'},
      ],
    },
    'expect': <String, Object?>{
      'entries': <Object?>[
        for (final FsDirEntry entry in entries)
          <String, Object?>{
            'name': entry.name,
            'type': entry.type.name,
            'size': entry.size,
            'displayPath': _path(entry.target.displayPath),
          },
      ],
      'listFile': onFile,
    },
  };
}

/// remove：文件 / 递归目录 / 缺失静默。
Future<Map<String, Object?>> _removeCase() async {
  final LocalFileSystem fs = LocalFileSystem(cwd: _tempDir().path);
  _write('ops/remove/file.txt', 'x');
  _write('ops/remove/tree/deep/file.txt', 'y');
  final FsTarget file = await fs.resolve('${_tempDir().path}/ops/remove/file.txt');
  final FsTarget tree = await fs.resolve('${_tempDir().path}/ops/remove/tree');
  final FsTarget ghost = await fs.resolve('${_tempDir().path}/ops/remove/ghost.txt');
  await fs.remove(file);
  final FsInfo? afterFile = await fs.stat(file);
  await fs.remove(tree);
  final FsInfo? afterTree = await fs.stat(tree);
  final Object? removeMissing = await _guard(() async => await fs.remove(ghost));

  return <String, Object?>{
    'scenario': 'remove',
    'label': 'remove：删文件、递归删目录、缺失静默',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'ops/remove/file.txt', 'content': 'x'},
        <String, Object?>{'name': 'ops/remove/tree/deep/file.txt', 'content': 'y'},
      ],
    },
    'expect': <String, Object?>{
      'fileGone': afterFile == null,
      'treeGone': afterTree == null,
      'removeMissing': removeMissing ?? 'silent',
    },
  };
}

// ───────────────────────────── shell ─────────────────────────────

/// kind = shell-resolve：缺省补齐与封顶。
Future<Map<String, Object?>> _shellResolve() async {
  final LocalShellExecutor executor = LocalShellExecutor(
    cwd: _tempDir().path,
    timeoutMs: 120000,
    maxTimeoutMs: 600000,
    maxOutputBytes: 64000,
  );
  ShellExecSpec spec(ShellExecRequest request) => executor.resolve(request);

  Map<String, Object?> project(ShellExecSpec s) => <String, Object?>{
        'command': s.command,
        'workdir': _path(s.workdir),
        'timeoutMs': s.timeoutMs,
        'stdoutMaxBytes': s.stdoutMaxBytes,
        'hasStdin': s.stdin != null,
        'env': s.env,
      };

  return <String, Object?>{
    'name': 'shell-resolve',
    'kind': 'shell-resolve',
    'root': _rootToken,
    'cases': <Object?>[
      <String, Object?>{
        'label': '缺省补齐：实例默认超时与采集上限、实例 cwd',
        'expect': project(spec(const ShellExecRequest(command: 'echo hi'))),
      },
      <String, Object?>{
        'label': '请求值优先于实例默认',
        'expect': project(spec(const ShellExecRequest(
            command: 'echo hi', timeoutMs: 5000, stdoutMaxBytes: 128))),
      },
      <String, Object?>{
        'label': '超时封顶到 maxTimeoutMs',
        'expect': project(spec(const ShellExecRequest(
            command: 'echo hi', timeoutMs: 9000000))),
      },
      <String, Object?>{
        'label': 'workdir 覆盖、stdin 与 env 透传',
        'expect': project(spec(ShellExecRequest(
            command: 'cat',
            workdir: '/tmp',
            stdin: 'hi',
            env: <String, String>{'K': 'V'}))),
      },
    ],
  };
}

/// kind = shell-run：退出码 / stderr / 超时 / stdin。
Future<Map<String, Object?>> _shellRun() async {
  final LocalShellExecutor executor =
      LocalShellExecutor(cwd: _tempDir().path, timeoutMs: 2000);
  Future<Map<String, Object?>> run(
    ShellExecRequest request, {
    bool projectExitCode = true,
  }) async {
    final ShellRunResult result = await executor.run(executor.resolve(request));
    return <String, Object?>{
      // 被信号杀死时 Dart 给 -9、Foundation 给信号号（正数）——符号是运行时细节，
      // 协议只要求「非 0」，故这类用例不投影原始码。
      if (projectExitCode)
        'exitCode': result.exitCode
      else
        'exitCodeIsNonZero': (result.exitCode ?? 0) != 0,
      'timedOut': result.timedOut,
      'timeoutMs': result.timeoutMs,
      'stdout': result.stdout.text,
      'stdoutTruncated': result.stdout.truncated ?? false,
      'stderr': result.stderr.text,
      'stderrTruncated': result.stderr.truncated ?? false,
    };
  }

  return <String, Object?>{
    'name': 'shell-run',
    'kind': 'shell-run',
    'cases': <Object?>[
      <String, Object?>{
        'label': '正常退出：退出码与输出',
        'input': <String, Object?>{'command': 'echo hello'},
        'expect': await run(const ShellExecRequest(command: 'echo hello')),
      },
      <String, Object?>{
        'label': '非零退出照常返回（不 reject）',
        'input': <String, Object?>{'command': 'exit 3'},
        'expect': await run(const ShellExecRequest(command: 'exit 3')),
      },
      <String, Object?>{
        'label': 'stderr 单独采集',
        'input': <String, Object?>{'command': 'echo oops >&2'},
        'expect': await run(const ShellExecRequest(command: 'echo oops >&2')),
      },
      <String, Object?>{
        'label': 'stdin 写入后关闭',
        'input': <String, Object?>{'command': 'cat', 'stdin': '喂你\n'},
        'expect': await run(const ShellExecRequest(command: 'cat', stdin: '喂你\n')),
      },
      <String, Object?>{
        'label': '超时中断：timedOut 为真且退出码非 0',
        'input': <String, Object?>{
          'command': 'sleep 5',
          'timeoutMs': 300,
          // 被信号杀死：退出码只断言「非 0」，符号随运行时而异。
          'signaledExit': true,
        },
        'expect': await run(
          const ShellExecRequest(command: 'sleep 5', timeoutMs: 300),
          projectExitCode: false,
        ),
      },
      <String, Object?>{
        'label': '采集上限截断：超出部分置 truncated',
        'input': <String, Object?>{
          'command': 'head -c 2000 /dev/zero | tr "\\0" "a"',
          'stdoutMaxBytes': 100,
        },
        'expect': await run(ShellExecRequest(
            command: 'head -c 2000 /dev/zero | tr "\\0" "a"',
            stdoutMaxBytes: 100)),
      },
    ],
  };
}

/// kind = shell-start：后台句柄的增量读取与 kill。
Future<Map<String, Object?>> _shellStart() async {
  final LocalShellExecutor executor = LocalShellExecutor(cwd: _tempDir().path);
  return <String, Object?>{
    'name': 'shell-start',
    'kind': 'shell-start',
    'cases': <Object?>[
      await _startEchoCase(executor),
      await _startKillCase(executor),
    ],
  };
}

/// 正常结束的后台进程：done 落定后一次读尽，再读为空。
Future<Map<String, Object?>> _startEchoCase(
    LocalShellExecutor executor) async {
  final ShellProcess process =
      await executor.start(executor.resolve(const ShellExecRequest(command: 'echo ready')));
  await process.done;
  final ShellProcessRead first = process.readOutput();
  final ShellProcessRead second = process.readOutput();
  return <String, Object?>{
    'scenario': 'echo',
    'label': '后台进程：done 落定后增量读完，第二次读为空',
    'input': <String, Object?>{'command': 'echo ready'},
    'expect': <String, Object?>{
      'status': process.status.name,
      'exitCode': process.exitCode,
      'delta': first.delta,
      'secondDeltaEmpty': second.delta.isEmpty,
      'killAfterDone': process.kill(),
    },
  };
}

/// 被 kill 的后台进程：状态转 killed、退出码为负、再次 kill 返回 false。
Future<Map<String, Object?>> _startKillCase(
    LocalShellExecutor executor) async {
  final ShellProcess process =
      await executor.start(executor.resolve(const ShellExecRequest(command: 'sleep 30')));
  final bool firstKill = process.kill();
  await process.done;
  final bool secondKill = process.kill();
  return <String, Object?>{
    'scenario': 'kill',
    'label': '后台进程：kill 后状态转 killed、退出码非 0、重复 kill 返回 false',
    'input': <String, Object?>{'command': 'sleep 30', 'signaledExit': true},
    'expect': <String, Object?>{
      'firstKill': firstKill,
      'status': process.status.name,
      'exitCodeIsNonZero': (process.exitCode ?? 0) != 0,
      'secondKill': secondKill,
    },
  };
}
