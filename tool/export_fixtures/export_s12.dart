// S12 凭据 v1.1 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 覆盖 file / vault / aws 三来源：请求形状、解析展开、只读与错误码、fallback。
//
// 统一形状：每个用例自带**输入**（文件内容 / 响应体 / 状态码 / 网络故障开关）与期望，
// Swift 侧运行器据此驱动替身，保证 fixture 自描述、不把输入藏在导出器里。
// 时间不入投影（过期判定用固定 now）；AWS 签名头只投影稳定形状（日期与签名逐次变化）。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_credentials/conatus_credentials.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'file-source': _fileSource,
    'vault-source': _vaultSource,
    'aws-source': _awsSource,
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s12');
}

/// 凭据表投影：键 → {value, expiresAt}（测试用假值，无真实机密）。
/// **已过期的键仍在 `keys` 里但 get 视为没有**（S12 §5），故表里跳过它们——
/// `keys` 单独投影，两者一起才能锁住「过期即视为没有」这条语义。
Map<String, Object?> _table(Credentials credentials) => <String, Object?>{
      for (final String key in credentials.keys.toList()..sort())
        if (credentials.get(key) case final Credential credential)
          key: <String, Object?>{
            'value': credential.value,
            'expiresAt': credential.expiresAt?.toUtc().toIso8601String(),
          },
    };

String _code(Object error) =>
    error is CredentialsException ? error.code : error.runtimeType.toString();

// ───────────────────────────── 文件来源 ─────────────────────────────

/// 两形态混合的凭据文件内容（含两个非法项）。
String _twoFormsContent() => jsonEncode(<String, Object?>{
      'ARK_API_KEY': 'sk-file',
      'DEEPSEEK_API_KEY': <String, Object?>{
        'value': 'ds-file',
        'expiresAt': '2026-01-01T00:00:00Z',
      },
      'BAD_NUMBER': 42,
      'BAD_OBJECT': <String, Object?>{'noValue': 'x'},
    });

Future<Map<String, Object?>> _fileSource() async {
  final Directory dir = Directory.systemTemp.createTempSync('swiftus-s12');
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  Future<Map<String, Object?>> run(
    List<Map<String, Object?>> files,
    Map<String, String>? fallback,
  ) async {
    for (final Map<String, Object?> file in files) {
      final String name = '${file['name']}';
      if (file['content'] == null) {
        final File stale = File('${dir.path}/$name');
        if (stale.existsSync()) stale.deleteSync();
      } else {
        File('${dir.path}/$name').writeAsStringSync('${file['content']}');
      }
    }
    final String path = '${dir.path}/${files.first['name']}';
    final FileCredentials credentials = FileCredentials(
      path: path,
      fallback: fallback ?? const <String, String>{},
    );
    String thrown = '';
    try {
      await credentials.load();
    } catch (error) {
      thrown = _code(error);
    }
    return <String, Object?>{
      'file': files.first['name'],
      'snapshot': _table(credentials),
      'keys': credentials.keys.toList()..sort(),
      'thrown': thrown,
    };
  }

  cases.add(<String, Object?>{
    'scenario': 'load',
    'label': '两种形态都读入，非法项跳过',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'two-forms.json', 'content': _twoFormsContent()},
      ],
      'fallback': null,
    },
    'expect': <String, Object?>{
      'results': <Object?>[await run(
        <Map<String, Object?>>[
          <String, Object?>{'name': 'two-forms.json', 'content': _twoFormsContent()},
        ],
        null,
      )],
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'load',
    'label': '文件不存在用 fallback 兜底',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'missing.json', 'content': null},
      ],
      'fallback': <String, String>{'FALLBACK_KEY': 'fallback-value'},
    },
    'expect': <String, Object?>{
      'results': <Object?>[await run(
        <Map<String, Object?>>[
          <String, Object?>{'name': 'missing.json', 'content': null},
        ],
        <String, String>{'FALLBACK_KEY': 'fallback-value'},
      )],
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'load',
    'label': '文件不存在且无 fallback 时快照为空',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'missing.json', 'content': null},
      ],
      'fallback': null,
    },
    'expect': <String, Object?>{
      'results': <Object?>[await run(
        <Map<String, Object?>>[
          <String, Object?>{'name': 'missing.json', 'content': null},
        ],
        null,
      )],
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'load',
    'label': '非法 JSON 抛错；顶层非对象按空表处理',
    'input': <String, Object?>{
      'files': <Object?>[
        <String, Object?>{'name': 'broken.json', 'content': '{ 不是 JSON'},
        <String, Object?>{'name': 'not-object.json', 'content': '["a", "b"]'},
      ],
      'fallback': null,
    },
    'expect': <String, Object?>{
      'results': <Object?>[
        await run(
          <Map<String, Object?>>[
            <String, Object?>{'name': 'broken.json', 'content': '{ 不是 JSON'},
          ],
          null,
        ),
        await run(
          <Map<String, Object?>>[
            <String, Object?>{'name': 'not-object.json', 'content': '["a", "b"]'},
          ],
          null,
        ),
      ],
    },
  });

  final FileCredentials readOnly = FileCredentials(path: '${dir.path}/two-forms.json');
  await readOnly.load();
  cases.add(<String, Object?>{
    'scenario': 'read-only',
    'label': '文件来源只读：update 抛 read-only',
    'input': <String, Object?>{'file': 'two-forms.json'},
    'expect': <String, Object?>{'code': await _updateCode(readOnly)},
  });

  dir.deleteSync(recursive: true);
  return <String, Object?>{'name': 'file-source', 'kind': 'file-source', 'cases': cases};
}

Future<String> _updateCode(Credentials credentials) async {
  try {
    await credentials.update('K', 'v');
    return '';
  } catch (error) {
    return _code(error);
  }
}

// ───────────────────────────── 替身 ─────────────────────────────

/// 记录请求并按输入返回固定响应的替身。
class _Recorder {
  _Recorder(this.status, this.body, {this.networkError = false});

  final int status;
  final String body;
  final bool networkError;
  http.Request? last;

  MockClient get client => MockClient((http.Request request) async {
        last = request;
        if (networkError) throw const SocketException('connection refused');
        return http.Response(
          body,
          status,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
}

Map<String, Object?> _requestShape(http.Request? request) {
  if (request == null) return <String, Object?>{'sent': false};
  final Map<String, String> raw = request.headers;
  final Map<String, String> lower = <String, String>{
    for (final MapEntry<String, String> entry in raw.entries)
      entry.key.toLowerCase(): entry.value,
  };
  return <String, Object?>{
    'sent': true,
    'method': request.method,
    'url': request.url.toString(),
    'contentType': lower['content-type'],
    'token': lower['x-vault-token'],
    'target': lower['x-amz-target'],
    'hasSessionToken': lower.containsKey('x-amz-security-token'),
    'contentSha256': lower['x-amz-content-sha256'],
    'amzDateFormat': RegExp(r'^\d{8}T\d{6}Z$').hasMatch('${lower['x-amz-date']}'),
    'authorization': _authorizationShape(lower['authorization']),
    'body': request.body,
  };
}

/// Authorization 头的稳定形状：算法 / accessKey / dateStamp 形态 / region /
/// service / scope 后缀 / SignedHeaders / 签名长度（日期与签名逐次变化）。
Map<String, Object?> _authorizationShape(String? authorization) {
  if (authorization == null) return <String, Object?>{'present': false};
  final Match? match = RegExp(
    r'^AWS4-HMAC-SHA256 Credential=([^/]+)/([^/]+)/([^/]+)/([^/]+)/aws4_request, SignedHeaders=([^,]+), Signature=(.+)$',
  ).firstMatch(authorization);
  if (match == null) {
    return <String, Object?>{'present': true, 'parsed': false};
  }
  return <String, Object?>{
    'present': true,
    'parsed': true,
    'algorithm': 'AWS4-HMAC-SHA256',
    'accessKey': match.group(1),
    'dateStampFormat': RegExp(r'^\d{8}$').hasMatch(match.group(2)!),
    'region': match.group(3),
    'service': match.group(4),
    'scopeSuffix': '${match.group(3)}/${match.group(4)}/aws4_request',
    'signedHeaders': match.group(5)!.split(';'),
    'signatureLength': match.group(6)!.length,
  };
}

// ───────────────────────────── Vault 来源 ─────────────────────────────

const VaultConfig _vaultConfig = VaultConfig(
  address: 'http://127.0.0.1:8200/',
  token: 'vault-token',
  path: 'conatus/llm',
);

Future<Map<String, Object?>> _vaultSource() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  /// 一次 refresh：返回 {request, snapshot, keys, code}。
  Future<Map<String, Object?>> pull(
    _Recorder recorder, {
    VaultConfig? config,
  }) async {
    final VaultCredentials credentials =
        VaultCredentials(config: config ?? _vaultConfig, client: recorder.client);
    String code = '';
    try {
      await credentials.refresh();
    } catch (error) {
      code = _code(error);
    }
    return <String, Object?>{
      'request': _requestShape(recorder.last),
      'snapshot': _table(credentials),
      'keys': credentials.keys.toList()..sort(),
      'code': code,
    };
  }

  final String dataBody = jsonEncode(<String, Object?>{
    'data': <String, Object?>{
      'data': <String, Object?>{
        'ARK_API_KEY': 'vault-key',
        'DEEPSEEK_API_KEY': <String, Object?>{'value': 'ds-key'},
      },
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'refresh',
    'label': 'URL / 方法 / Token 头正确并解析 data.data',
    'input': <String, Object?>{
      'status': 200,
      'body': dataBody,
      'networkError': false,
      'address': 'http://127.0.0.1:8200/',
      'token': 'vault-token',
      'path': 'conatus/llm',
      'mount': 'secret',
    },
    'expect': <String, Object?>{
      'result': await pull(_Recorder(200, dataBody)),
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'refresh',
    'label': '地址末尾斜杠规范化：多斜杠与根路径都拼出同一 URL',
    'input': <String, Object?>{
      'status': 200,
      'body': dataBody,
      'networkError': false,
      'address': 'http://127.0.0.1:8200///',
      'token': 'vault-token',
      'path': 'conatus/llm',
      'mount': 'kv2',
    },
    'expect': <String, Object?>{
      'result': await pull(
        _Recorder(200, dataBody),
        config: const VaultConfig(
          address: 'http://127.0.0.1:8200///',
          token: 'vault-token',
          path: 'conatus/llm',
          mount: 'kv2',
        ),
      ),
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'http-error',
    'label': '非 200 抛 vault-http',
    'input': <String, Object?>{'status': 403, 'body': 'permission denied', 'networkError': false},
    'expect': <String, Object?>{
      'code': (await pull(_Recorder(403, 'permission denied')))['code'],
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'network-error',
    'label': '网络异常抛 vault-network',
    'input': <String, Object?>{'networkError': true},
    'expect': <String, Object?>{
      'code': (await pull(_Recorder(0, '', networkError: true)))['code'],
    },
  });

  final List<Object?> shapes = <Object?>[
    <String, Object?>{'data': 'not-an-object'},
    <String, Object?>{'nodata': 1},
    <String, Object?>{'data': <String, Object?>{'data': <Object?>['a']}},
  ];
  final List<Object?> shapeResults = <Object?>[];
  for (final Object? body in shapes) {
    shapeResults.add(await pull(_Recorder(200, jsonEncode(body))));
  }
  cases.add(<String, Object?>{
    'scenario': 'shape',
    'label': '响应形状异常一律空表，不抛错',
    'input': <String, Object?>{'bodies': shapes.map(jsonEncode).toList()},
    'expect': <String, Object?>{'results': shapeResults},
  });

  final VaultCredentials readOnly =
      VaultCredentials(config: _vaultConfig, client: _Recorder(200, dataBody).client);
  await readOnly.refresh();
  cases.add(<String, Object?>{
    'scenario': 'read-only',
    'label': 'Vault 来源只读：update 抛 read-only',
    'expect': <String, Object?>{'code': await _updateCode(readOnly)},
  });

  return <String, Object?>{'name': 'vault-source', 'kind': 'vault-source', 'cases': cases};
}

// ───────────────────────────── AWS Secrets Manager 来源 ─────────────────────────────

const AwsSecretsConfig _awsConfig = AwsSecretsConfig(
  accessKey: 'AKIDEXAMPLE',
  secretKey: 'SECRET',
  region: 'us-east-1',
  secretId: 'conatus/llm',
);

Future<Map<String, Object?>> _awsSource() async {
  final List<Map<String, Object?>> cases = <Map<String, Object?>>[];

  Future<Map<String, Object?>> pull(
    _Recorder recorder, {
    AwsSecretsConfig? config,
  }) async {
    final AwsSecretsCredentials credentials =
        AwsSecretsCredentials(config: config ?? _awsConfig, client: recorder.client);
    String code = '';
    try {
      await credentials.refresh();
    } catch (error) {
      code = _code(error);
    }
    return <String, Object?>{
      'request': _requestShape(recorder.last),
      'snapshot': _table(credentials),
      'keys': credentials.keys.toList()..sort(),
      'code': code,
    };
  }

  final String expandedBody = jsonEncode(<String, Object?>{
    'SecretString': jsonEncode(<String, Object?>{
      'ARK_API_KEY': 'aws-key',
      'DEEPSEEK_API_KEY': <String, Object?>{'value': 'ds-key'},
    }),
  });
  cases.add(<String, Object?>{
    'scenario': 'refresh',
    'label': 'POST / GetSecretValue + SigV4 头，SecretString 为 JSON 时展开',
    'input': <String, Object?>{'status': 200, 'body': expandedBody, 'networkError': false},
    'expect': <String, Object?>{
      'result': await pull(_Recorder(200, expandedBody)),
    },
  });

  const String plainBody = '{"SecretString": "plain-secret"}';
  cases.add(<String, Object?>{
    'scenario': 'refresh',
    'label': 'SecretString 为纯文本时以 secretId 为单一键',
    'input': <String, Object?>{'status': 200, 'body': plainBody, 'networkError': false},
    'expect': <String, Object?>{
      'result': await pull(_Recorder(200, plainBody)),
    },
  });

  const String notJsonBody = '{"SecretString": "not-json"}';
  cases.add(<String, Object?>{
    'scenario': 'refresh',
    'label': 'SecretString 非 JSON 时同样退化为单一键',
    'input': <String, Object?>{'status': 200, 'body': notJsonBody, 'networkError': false},
    'expect': <String, Object?>{
      'result': await pull(_Recorder(200, notJsonBody)),
    },
  });

  const String customBody = '{"SecretString": "custom"}';
  cases.add(<String, Object?>{
    'scenario': 'endpoint',
    'label': 'endpoint 覆盖 + 会话令牌进入签名与请求头',
    'input': <String, Object?>{
      'status': 200,
      'body': customBody,
      'networkError': false,
      'accessKey': 'ASIAEXAMPLE',
      'region': 'eu-west-1',
      'sessionToken': 'SESSION',
      'endpoint': 'http://127.0.0.1:4566/',
    },
    'expect': <String, Object?>{
      'result': await pull(
        _Recorder(200, customBody),
        config: const AwsSecretsConfig(
          accessKey: 'ASIAEXAMPLE',
          secretKey: 'SECRET',
          region: 'eu-west-1',
          secretId: 'conatus/llm',
          sessionToken: 'SESSION',
          endpoint: 'http://127.0.0.1:4566/',
        ),
      ),
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'http-error',
    'label': '非 200 抛 aws-http',
    'input': <String, Object?>{'status': 403, 'body': 'denied', 'networkError': false},
    'expect': <String, Object?>{
      'code': (await pull(_Recorder(403, 'denied')))['code'],
    },
  });

  cases.add(<String, Object?>{
    'scenario': 'network-error',
    'label': '网络异常抛 aws-network',
    'input': <String, Object?>{'networkError': true},
    'expect': <String, Object?>{
      'code': (await pull(_Recorder(0, '', networkError: true)))['code'],
    },
  });

  final List<Object?> shapes = <Object?>[
    <String, Object?>{'SecretString': 42},
    <String, Object?>{'nope': 'x'},
  ];
  final List<Object?> shapeResults = <Object?>[];
  for (final Object? body in shapes) {
    shapeResults.add(await pull(_Recorder(200, jsonEncode(body))));
  }
  cases.add(<String, Object?>{
    'scenario': 'shape',
    'label': '响应形状异常一律空表，不抛错',
    'input': <String, Object?>{'bodies': shapes.map(jsonEncode).toList()},
    'expect': <String, Object?>{'results': shapeResults},
  });

  final AwsSecretsCredentials readOnly =
      AwsSecretsCredentials(config: _awsConfig, client: _Recorder(200, expandedBody).client);
  await readOnly.refresh();
  cases.add(<String, Object?>{
    'scenario': 'read-only',
    'label': 'AWS 来源只读：update 抛 read-only',
    'expect': <String, Object?>{'code': await _updateCode(readOnly)},
  });

  return <String, Object?>{'name': 'aws-source', 'kind': 'aws-source', 'cases': cases};
}
