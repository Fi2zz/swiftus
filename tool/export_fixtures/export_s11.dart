// S11 MCP 客户端 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 用例自带输入：JSON 载荷、字节流、消息序列、超时配置都写进 `input`。
//
// 归一化（S11 专用）：
// - **无时间语义**：本规格没有墙钟与时区，故不需要钉 TZ（与 S9 不同）；
// - 消息 id 逐字保留（客户端自增整数 id 是协议的一部分）；
// - 传输的「一次性」语义只投影布尔（`connected` 复位），不投影内部状态机；
// - 传输层（stdio / http / sse）不进 fixtures：它们要么要真子进程，要么要
//   HTTP 桩（语言相关的注入点），由 Swift 侧单元测试守，端到端由 Demo 守。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conatus_core/conatus_core.dart';
import 'package:conatus_credentials/conatus_credentials.dart';
import 'package:conatus_foundation/conatus_foundation.dart';
import 'package:conatus_mcp/conatus_mcp.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'mcp-config': _mcpConfig,
    'mcp-protocol': _mcpProtocol,
    'mcp-sse': _mcpSse,
    'mcp-content': _mcpContent,
    'mcp-risk': _mcpRisk,
    'mcp-client': _mcpClient,
    'mcp-registry': _mcpRegistry,
  };
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, Future<Map<String, Object?>> Function()> entry
      in fixtures.entries) {
    final Map<String, Object?> fixture =
        await Future<Map<String, Object?>>.sync(entry.value);
    File('${outDir.path}/${entry.key}.json')
        .writeAsStringSync('${encoder.convert(fixture)}\n');
    stdout.writeln('导出 ${entry.key}.json');
  }
}

Directory _outputDir() {
  final Directory here = File.fromUri(Platform.script).parent;
  return Directory('${here.parent.parent.path}/spec/fixtures/s11');
}

/// 尽力执行并把异常收敛成 `{error: {code, message}}`。
Future<Object?> _guard(Future<Object?> Function() body) async {
  try {
    return await body();
  } on McpException catch (error) {
    return <String, Object?>{
      'error': <String, Object?>{
        'code': error.code,
        'message': _normalize(error.message),
      },
    };
  } on ArgumentError catch (error) {
    return <String, Object?>{
      'invalid': <String, Object?>{
        'name': error.name.toString(),
        'message': error.message,
      },
    };
  } on StateError catch (error) {
    return <String, Object?>{'state': error.message};
  } on Object catch (error) {
    return <String, Object?>{'unexpected': '$error'};
  }
}

/// `ArgumentError.value` 的 name 形如 `name` / `command` / `url`。
String _argumentName(Object? name) {
  final String raw = name.toString();
  return raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2
      ? raw.substring(1, raw.length - 1)
      : raw;
}

/// 抹掉语言专属的 `toString` 形态，只留语义。
///
/// 两处来源侧渲染与 Swift 不可逐字对应：
/// - 枚举拼进消息：`McpTransportType.http 传输需要 url` —— 锁的语义是
///   「哪个传输类型缺哪个字段」，不是 Dart 的枚举名；
/// - 异常 `toString` 嵌进断连消息：`...：McpException(server-exited): 子进程退出`
///   —— 锁的语义是「断连原因整段透传进待办失败消息」。
String _normalize(String message) => message
    .replaceAll(RegExp(r'McpTransportType\.'), '')
    .replaceAllMapped(
      RegExp(r'McpException\(([^)]+)\): '),
      (Match match) => 'mcp-error(${match.group(1)}): ',
    );

// ───────────────────────────── 配置校验 ─────────────────────────────

/// kind = mcp-config：构造期校验与凭据占位符。
Future<Map<String, Object?>> _mcpConfig() async {
  const List<Map<String, Object?>> cases = <Map<String, Object?>>[
    <String, Object?>{
      'label': 'stdio + command',
      'input': <String, Object?>{'name': 'fs', 'type': 'stdio', 'command': 'npx'},
    },
    <String, Object?>{
      'label': 'stdio 缺 command',
      'input': <String, Object?>{'name': 'fs', 'type': 'stdio'},
    },
    <String, Object?>{
      'label': 'stdio command 为空串（视为缺）',
      'input': <String, Object?>{'name': 'fs', 'type': 'stdio', 'command': ''},
    },
    <String, Object?>{
      'label': 'http + url',
      'input': <String, Object?>{
        'name': 'r',
        'type': 'http',
        'url': 'https://mcp.test/mcp',
        'headers': <String, String>{'Authorization': 'Bearer x'},
      },
    },
    <String, Object?>{
      'label': 'http 缺 url',
      'input': <String, Object?>{'name': 'r', 'type': 'http'},
    },
    <String, Object?>{
      'label': 'sse + url',
      'input': <String, Object?>{
        'name': 'r',
        'type': 'sse',
        'url': 'https://mcp.test/sse',
      },
    },
    <String, Object?>{
      'label': 'sse url 为空串（视为缺）',
      'input': <String, Object?>{'name': 'r', 'type': 'sse', 'url': ''},
    },
    <String, Object?>{
      'label': '名为空串',
      'input': <String, Object?>{'name': '', 'type': 'stdio', 'command': 'npx'},
    },
  ];

  Future<Map<String, Object?>> _expectFor(int index) async {
    final Map<String, Object?> input =
        cases[index]['input']! as Map<String, Object?>;
    try {
      final McpServerConfig config = McpServerConfig(
        name: input['name']! as String,
        type: McpTransportType.values.byName(input['type']! as String),
        command: input['command'] as String?,
        args: (input['args'] as List<Object?>?)?.cast<String>() ??
            const <String>[],
        env: (input['env'] as Map<String, Object?>?)?.cast<String, String>() ??
            const <String, String>{},
        url: input['url'] as String?,
        headers:
            (input['headers'] as Map<String, Object?>?)?.cast<String, String>() ??
                const <String, String>{},
      );
      return <String, Object?>{
        'name': config.name,
        'type': config.type.name,
        'command': config.command,
        'args': config.args,
        'env': config.env,
        'url': config.url,
        'headers': config.headers,
      };
    } on ArgumentError catch (error) {
      return <String, Object?>{
        'invalid': <String, Object?>{
          'name': _argumentName(error.name),
          'message': _normalize(error.message),
        },
      };
    }
  }

  // 凭据占位符：解析得到值 / 解析不到原样保留。
  final InMemoryCredentials credentials =
      InMemoryCredentials(initial: <String, String>{'REMOTE_TOKEN': 'tok-1'});
  const Map<String, String> raw = <String, String>{
    'header': 'Bearer \${REMOTE_TOKEN}',
    'env': '\${REMOTE_TOKEN}=\${MISSING_KEY}',
    'plain': '没有占位符',
    'multi': '\${REMOTE_TOKEN}/\${REMOTE_TOKEN}',
  };

  return <String, Object?>{
    'name': 'mcp-config',
    'kind': 'mcp-config',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'validate',
        'label': '配置构造期校验：name 非空、stdio 需 command、http/sse 需 url（空串视为缺）',
        'input': cases,
        'expect': <Object?>[for (int i = 0; i < cases.length; i++) await _expectFor(i)],
      },
      <String, Object?>{
        'scenario': 'placeholders',
        'label': '`\${KEY}` 占位符：能解析的替换、解析不到的（无服务/无键）原样保留',
        'input': <String, Object?>{
          'values': raw,
          'credentials': <String, String>{'REMOTE_TOKEN': 'tok-1'},
        },
        'expect': <String, Object?>{
          'withCredentials': resolveCredentialPlaceholders(raw, credentials),
          'withoutCredentials': resolveCredentialPlaceholders(
            <String, String>{'header': 'Bearer \${REMOTE_TOKEN}'},
            null,
          ),
        },
      },
    ],
  };
}

// ───────────────────────────── 协议词汇 ─────────────────────────────

/// kind = mcp-protocol：消息信封、错误对象、握手结果。
Future<Map<String, Object?>> _mcpProtocol() async {
  const List<Map<String, Object?>> messages = <Map<String, Object?>>[
    <String, Object?>{
      'label': '请求',
      'json': <String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
        'params': <String, Object?>{'cursor': 'c'},
      },
    },
    <String, Object?>{
      'label': '通知（无 id，单向）',
      'json': <String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
    },
    <String, Object?>{
      'label': '成功响应（无 method）',
      'json': <String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'result': <String, Object?>{'tools': <Object?>[]},
      },
    },
    <String, Object?>{
      'label': '失败响应',
      'json': <String, Object?>{
        'jsonrpc': '2.0',
        'id': 2,
        'error': <String, Object?>{
          'code': -32601,
          'message': '方法不存在',
          'data': <String, Object?>{'hint': 'x'},
        },
      },
    },
    <String, Object?>{
      'label': '字符串 id 的请求',
      'json': <String, Object?>{'jsonrpc': '2.0', 'id': 'abc', 'method': 'ping'},
    },
    <String, Object?>{
      'label': '服务端主动请求（有 id 有 method）',
      'json': <String, Object?>{'jsonrpc': '2.0', 'id': 9, 'method': 'roots/list'},
    },
    <String, Object?>{
      'label': '畸形：method 不是字符串 → 该字段为空（连通知都不是）',
      'json': <String, Object?>{'jsonrpc': '2.0', 'id': 3, 'method': 42},
    },
    <String, Object?>{
      'label': '畸形：params 不是对象 → params 为空',
      'json': <String, Object?>{
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'x',
        'params': '不是对象',
      },
    },
    <String, Object?>{
      'label': '畸形：error 不是对象 → 无 error（按成功响应序列化）',
      'json': <String, Object?>{'jsonrpc': '2.0', 'id': 5, 'error': '炸了'},
    },
    <String, Object?>{
      'label': '畸形：错误对象缺 code 与 message → 退 0 与空串',
      'json': <String, Object?>{
        'jsonrpc': '2.0',
        'id': 6,
        'error': <String, Object?>{},
      },
    },
  ];

  const List<Map<String, Object?>> handshakes = <Map<String, Object?>>[
    <String, Object?>{
      'label': '标准形态（服务端版本不同也照收不误）',
      'json': <String, Object?>{
        'protocolVersion': '2024-11-05',
        'capabilities': <String, Object?>{'tools': <String, Object?>{}},
        'serverInfo': <String, Object?>{'name': 'fake', 'version': '9.9'},
      },
    },
    <String, Object?>{
      'label': '顶层宽容形态（name/version 在顶层）',
      'json': <String, Object?>{
        'protocolVersion': '2025-06-18',
        'name': 'flat',
        'version': '1.0',
        'instructions': '怎么用',
      },
    },
    <String, Object?>{
      'label': '缺 protocolVersion → 退回本客户端声明的版本',
      'json': <String, Object?>{
        'serverInfo': <String, Object?>{'name': 'n'},
      },
    },
    <String, Object?>{
      'label': '缺 capabilities → 空对象',
      'json': <String, Object?>{'protocolVersion': '2025-06-18'},
    },
    <String, Object?>{
      'label': '字段类型不符 → 退缺省',
      'json': <String, Object?>{
        'protocolVersion': 42,
        'serverInfo': '不是对象',
        'capabilities': '不是对象',
      },
    },
  ];

  Map<String, Object?> messageProjection(Map<String, Object?> json) {
    final McpMessage message = McpMessage.fromJson(json);
    return <String, Object?>{
      'request': message.request,
      'notification': message.notification,
      'response': message.response,
      'toJson': message.toJson(),
    };
  }

  Map<String, Object?> handshakeProjection(Map<String, Object?> json) {
    final McpServerInfo info = McpServerInfo.fromJson(json);
    return <String, Object?>{
      'protocolVersion': info.protocolVersion,
      'name': info.name,
      'version': info.version,
      'instructions': info.instructions,
      'capabilities': info.capabilities,
    };
  }

  return <String, Object?>{
    'name': 'mcp-protocol',
    'kind': 'mcp-protocol',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'message',
        'label': '消息三态（method+id / method / 无 method）、jsonrpc 固定 2.0、畸形字段退缺省',
        'input': messages,
        'expect': <Object?>[
          for (final Map<String, Object?> item in messages)
            messageProjection(item['json']! as Map<String, Object?>),
        ],
      },
      <String, Object?>{
        'scenario': 'handshake',
        'label': '握手结果：标准形态 / 顶层宽容形态 / 缺字段退缺省（协议版本照收不误）',
        'input': handshakes,
        'expect': <Object?>[
          for (final Map<String, Object?> item in handshakes)
            handshakeProjection(item['json']! as Map<String, Object?>),
        ],
      },
      <String, Object?>{
        'scenario': 'const',
        'label': '本客户端声明的协议版本、工具名拼接与异常文案',
        'input': <String, Object?>{'server': 'fs', 'tool': 'read_file'},
        'expect': <String, Object?>{
          'protocolVersion': kMcpProtocolVersion,
          'toolName': mcpToolName('fs', 'read_file'),
          'exception': const McpException('timeout', '示例').toString(),
        },
      },
    ],
  };
}

// ───────────────────────────── SSE 解析 ─────────────────────────────

/// kind = mcp-sse：字节流 → 事件。
Future<Map<String, Object?>> _mcpSse() async {
  /// 每个 chunk 是一段**原始文本**（可切断行、切断字段、切断多字节字符）。
  Future<List<Map<String, Object?>>> parse(List<String> chunks) async {
    final StreamController<List<int>> source = StreamController<List<int>>();
    final List<SseEvent> events = <SseEvent>[];
    // 先建立订阅再喂字节：流的订阅时机坑。
    final Future<void> done = parseSseEvents(source.stream).forEach(events.add);
    for (final String chunk in chunks) {
      source.add(utf8.encode(chunk));
    }
    await source.close();
    await done;
    return <Map<String, Object?>>[
      for (final SseEvent event in events)
        <String, Object?>{
          'event': event.event,
          'data': event.data,
          'id': event.id,
        },
    ];
  }

  const List<Map<String, Object?>> cases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '多行 data 用换行拼接，空行派发',
      'chunks': <String>['data: 第一行\ndata: 第二行\n\n'],
    },
    <String, Object?>{
      'label': 'event / id 字段随事件带出',
      'chunks': <String>['event: endpoint\ndata: /messages?session=1\nid: 7\n\n'],
    },
    <String, Object?>{
      'label': '注释行忽略；只有注释的空块不派发',
      'chunks': <String>[': 这是注释\ndata: 有效\n\n', ': 只有注释\n\n'],
    },
    <String, Object?>{
      'label': '冒号后恰好一个空格被剥掉，其余保留',
      'chunks': <String>['data:  两个空格保留\ndata:只有一个值\n\n'],
    },
    <String, Object?>{
      'label': '无冒号的字段视为空值 → 该事件不派发',
      'chunks': <String>['data\nevent: message\n\n'],
    },
    <String, Object?>{
      'label': '跨 chunk 切分：半行、半字段都能重组',
      'chunks': <String>['da', 'ta: 前半\nda', 'ta: 后半\n\n'],
    },
    <String, Object?>{
      'label': 'EOF 时未派发的 data 也派发一次',
      'chunks': <String>['data: 结尾没有空行'],
    },
    <String, Object?>{
      'label': '多字节字符被 chunk 切断也不乱码',
      'chunks': <String>['data: 中文标', '题\n\n'],
    },
    <String, Object?>{
      'label': '多个事件按顺序派发，字段不复用',
      'chunks': <String>['event: a\ndata: 第一\n\nevent: b\ndata: 第二\n\n'],
    },
  ];

  return <String, Object?>{
    'name': 'mcp-sse',
    'kind': 'mcp-sse',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'parse',
        'label': 'SSE 解析：多行 data 拼接、空行派发、注释忽略、单空格剥掉、EOF 补派发、跨 chunk 重组',
        'input': cases,
        'expect': <Object?>[
          for (final Map<String, Object?> item in cases)
            await parse((item['chunks']! as List<Object?>).cast<String>()),
        ],
      },
    ],
  };
}

// ───────────────────────────── 内容块与结果 ─────────────────────────────

/// kind = mcp-content：内容块解析、人可读文本、结果 → ToolResult。
Future<Map<String, Object?>> _mcpContent() async {
  const List<Map<String, Object?>> resultCases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '纯文本块按换行分隔',
      'json': <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '第一段'},
          <String, Object?>{'type': 'text', 'text': '第二段'},
        ],
      },
    },
    <String, Object?>{
      'label': '非文本块给占位（有 MIME 用 MIME，没有用类型名）',
      'json': <String, Object?>{
        'content': <Object?>[
          <String, Object?>{
            'type': 'image',
            'data': 'base64…',
            'mimeType': 'image/png',
          },
          <String, Object?>{'type': 'resource'},
          <String, Object?>{'type': 'text', 'text': '尾段'},
        ],
      },
    },
    <String, Object?>{
      'label': '空文本块被跳过；type 缺失退 text',
      'json': <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': ''},
          <String, Object?>{'text': '没有 type 字段'},
        ],
      },
    },
    <String, Object?>{
      'label': 'isError → 失败：文本既作内容也作错误消息',
      'json': <String, Object?>{
        'isError': true,
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '工具执行失败'},
        ],
      },
    },
    <String, Object?>{
      'label': '成功：结构化结果进 value',
      'json': <String, Object?>{
        'structuredContent': <String, Object?>{'rows': 3},
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'ok'},
        ],
      },
    },
    <String, Object?>{
      'label': 'isError 为 false（非 true）→ 成功',
      'json': <String, Object?>{
        'isError': false,
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'fine'},
        ],
      },
    },
    <String, Object?>{
      'label': '空对象 → 空文本、空 value',
      'json': <String, Object?>{},
    },
    <String, Object?>{
      'label': 'content 不是列表 → 空内容',
      'json': <String, Object?>{'content': '不是列表'},
    },
  ];

  const List<Map<String, Object?>> describeCases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '多个文本块换行拼接',
      'blocks': <Object?>[
        <String, Object?>{'type': 'text', 'text': '一'},
        <String, Object?>{'type': 'text', 'text': '二'},
      ],
    },
    <String, Object?>{
      'label': '图片给 [mimeType] 占位',
      'blocks': <Object?>[
        <String, Object?>{
          'type': 'image',
          'data': 'x',
          'mimeType': 'image/jpeg',
        },
      ],
    },
    <String, Object?>{
      'label': '无 MIME 时退回类型名',
      'blocks': <Object?>[
        <String, Object?>{'type': 'resource'},
      ],
    },
    <String, Object?>{
      'label': '空列表 → 空串',
      'blocks': <Object?>[],
    },
    <String, Object?>{
      'label': '只有空文本块 → 空串',
      'blocks': <Object?>[
        <String, Object?>{'type': 'text', 'text': ''},
      ],
    },
  ];

  return <String, Object?>{
    'name': 'mcp-content',
    'kind': 'mcp-content',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'result',
        'label': 'tools/call 结果 → ToolResult：内容文本、占位、isError 失败码、结构化 value',
        'input': resultCases,
        'expect': <Object?>[
          for (final Map<String, Object?> item in resultCases)
            _resultProjection(
              toolResultFromMcp(
                McpToolResult.fromJson(item['json']! as Map<String, Object?>),
              ),
            ),
        ],
      },
      <String, Object?>{
        'scenario': 'describe',
        'label': '人可读文本：多行拼接、空块跳过、占位说明',
        'input': describeCases,
        'expect': <Object?>[
          for (final Map<String, Object?> item in describeCases)
            describeMcpContent(<McpContent>[
              for (final Object? block in item['blocks']! as List<Object?>)
                McpContent.fromJson(block! as Map<String, Object?>),
            ]),
        ],
      },
    ],
  };
}

/// ToolResult 的可投影形状：文本 / 是否失败 / 错误码 / 结构化值。
Map<String, Object?> _resultProjection(ToolResult result) => <String, Object?>{
      'text': result.content,
      'failed': result.isError,
      'code': result.error?.code,
      'value': result.value,
    };

// ───────────────────────────── 风险映射 ─────────────────────────────

/// kind = mcp-risk：MCP 风险信号 → 本地三级。
Future<Map<String, Object?>> _mcpRisk() async {
  const List<Map<String, Object?>> cases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '什么都没声明 → medium（默认需审批）',
      'json': <String, Object?>{'name': 't'},
    },
    <String, Object?>{
      'label': 'readOnlyHint → low',
      'json': <String, Object?>{
        'name': 't',
        'annotations': <String, Object?>{'readOnlyHint': true},
      },
    },
    <String, Object?>{
      'label': 'destructiveHint → high',
      'json': <String, Object?>{
        'name': 't',
        'annotations': <String, Object?>{'destructiveHint': true},
      },
    },
    <String, Object?>{
      'label': '两个注解同时给 → destructive 优先',
      'json': <String, Object?>{
        'name': 't',
        'annotations': <String, Object?>{
          'readOnlyHint': true,
          'destructiveHint': true,
        },
      },
    },
    <String, Object?>{
      'label': '注解为 false / 非布尔 → 落回默认',
      'json': <String, Object?>{
        'name': 't',
        'annotations': <String, Object?>{
          'readOnlyHint': false,
          'destructiveHint': 'yes',
        },
      },
    },
    <String, Object?>{
      'label': 'annotations 不是对象 → 空注解',
      'json': <String, Object?>{'name': 't', 'annotations': '不是对象'},
    },
    <String, Object?>{
      'label': 'riskLevel=readonly → low',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'readonly'},
    },
    <String, Object?>{
      'label': 'riskLevel=read → low',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'read'},
    },
    <String, Object?>{
      'label': 'riskLevel=READ（大小写不敏感）→ low',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'READ'},
    },
    <String, Object?>{
      'label': 'riskLevel=write → medium',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'write'},
    },
    <String, Object?>{
      'label': 'riskLevel=mutating → medium',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'mutating'},
    },
    <String, Object?>{
      'label': 'riskLevel=destructive → high',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'destructive'},
    },
    <String, Object?>{
      'label': 'riskLevel=admin → high',
      'json': <String, Object?>{'name': 't', 'riskLevel': 'admin'},
    },
    <String, Object?>{
      'label': '未知 riskLevel 标签 → 落回注解',
      'json': <String, Object?>{
        'name': 't',
        'riskLevel': 'weird',
        'annotations': <String, Object?>{'readOnlyHint': true},
      },
    },
    <String, Object?>{
      'label': 'riskLevel 优先于注解（destructive 标签 + readOnlyHint）',
      'json': <String, Object?>{
        'name': 't',
        'riskLevel': 'destructive',
        'annotations': <String, Object?>{'readOnlyHint': true},
      },
    },
  ];

  const List<Map<String, Object?>> schemaCases = <Map<String, Object?>>[
    <String, Object?>{
      'label': '透传服务端 inputSchema',
      'json': <String, Object?>{
        'name': 'read_file',
        'description': '读文件',
        'inputSchema': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{'type': 'string'},
          },
          'required': <Object?>['path'],
        },
      },
    },
    <String, Object?>{
      'label': '只有 title → 描述退 title',
      'json': <String, Object?>{'name': 'titled', 'title': '只有标题'},
    },
    <String, Object?>{
      'label': '什么都没有 → 描述退工具名；schema 退空对象形态',
      'json': <String, Object?>{'name': 'bare'},
    },
    <String, Object?>{
      'label': 'name 缺失（服务端异常形态）→ 空串名',
      'json': <String, Object?>{'description': '无名的工具'},
    },
  ];

  return <String, Object?>{
    'name': 'mcp-risk',
    'kind': 'mcp-risk',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'risk',
        'label': '风险映射顺序：非标准 riskLevel → destructiveHint → readOnlyHint → 默认 medium',
        'input': cases,
        'expect': <Object?>[
          for (final Map<String, Object?> item in cases)
            mcpToolRisk(McpTool.fromJson(item['json']! as Map<String, Object?>)).name,
        ],
      },
      <String, Object?>{
        'scenario': 'schema',
        'label': '工具适配：名字 server__tool、描述退级、分组 mcp:<server>、参数声明留空、入参透传',
        'input': <String, Object?>{
          'server': 'fs',
          'tools': schemaCases,
        },
        'expect': <Object?>[
          for (final Map<String, Object?> item in schemaCases)
            _schemaProjection(
              'fs',
              McpTool.fromJson(item['json']! as Map<String, Object?>),
            ),
        ],
      },
    ],
  };
}

/// 适配器的可投影形状（不建立连接）。
Map<String, Object?> _schemaProjection(String server, McpTool tool) {
  final McpToolAdapter adapter = McpToolAdapter(
    client: McpClient(transport: _NeverTransport(), serverName: server),
    tool: tool,
  );
  return <String, Object?>{
    'name': adapter.name,
    'description': adapter.description,
    'risk': adapter.riskLevel.name,
    'group': adapter.group,
    'params': adapter.params.map((ParamSpec spec) => spec.name).toList(),
    'schema': adapter.toSchema(),
  };
}

/// 永不连上的传输：只为投影 schema / 描述，不发起任何调用。
class _NeverTransport implements McpTransport {
  @override
  Stream<McpMessage> get messages => const Stream<McpMessage>.empty();

  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(McpMessage message) async {}
}

// ───────────────────────────── 客户端 ─────────────────────────────

/// kind = mcp-client：握手 / 发现（含翻页）/ 调用 / 断连与超时收敛。
Future<Map<String, Object?>> _mcpClient() async {
  // 场景 1：完整链路（握手 → 两页工具 → 调用）。
  final _ScriptedTransport good = _ScriptedTransport(
    initialize: <String, Object?>{
      'protocolVersion': '2024-11-05',
      'capabilities': <String, Object?>{},
      'serverInfo': <String, Object?>{'name': 'fake', 'version': '9.9'},
    },
    pages: <Object?>[
      <String, Object?>{
        'tools': <Object?>[
          <String, Object?>{
            'name': 'read_file',
            'description': '读',
            'inputSchema': <String, Object?>{'type': 'object'},
          },
        ],
        'nextCursor': 'c2',
      },
      <String, Object?>{
        'tools': <Object?>[
          <String, Object?>{'name': 'write_file', 'riskLevel': 'destructive'},
        ],
      },
    ],
    callResult: <String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': 'ok'},
      ],
      'structuredContent': <String, Object?>{'bytes': 12},
    },
  );
  final McpClient client = McpClient(transport: good, serverName: 'fs');
  final McpServerInfo info = await client.initialize();
  final List<McpTool> tools = await client.listTools();
  final McpToolResult called =
      await client.callTool('read_file', <String, Object?>{'path': '/tmp/a'});
  final Map<String, Object?> happy = <String, Object?>{
    'serverInfo': <String, Object?>{
      'protocolVersion': info.protocolVersion,
      'name': info.name,
      'version': info.version,
    },
    'ready': client.ready,
    'tools': <Object?>[
      for (final McpTool tool in tools)
        <String, Object?>{'name': tool.name, 'risk': mcpToolRisk(tool).name},
    ],
    'callText': describeMcpContent(called.content),
    'callFailed': called.failed,
    'callValue': called.structuredContent,
    'sent': good.sentLabels,
  };
  await client.close();
  happy['readyAfterClose'] = client.ready;
  happy['closedTwice'] = await _doubleClose(client);

  // 场景 2：翻页超限（服务端每页都回同一个游标）。
  final _ScriptedTransport looping = _ScriptedTransport(
    initialize: <String, Object?>{'protocolVersion': kMcpProtocolVersion},
    pages: <Object?>[
      <String, Object?>{
        'tools': <Object?>[
          <String, Object?>{'name': 'a'},
        ],
        'nextCursor': 'always-more',
      },
    ],
  );
  final McpClient loopingClient =
      McpClient(transport: looping, serverName: 'loop');
  await loopingClient.initialize();
  final Object? tooManyPages = await _guard(() async {
    final List<McpTool> found = await loopingClient.listTools();
    return <String, Object?>{'count': found.length};
  });
  await loopingClient.close();

  // 场景 3：协议错误（响应带 error 对象）。
  final _ScriptedTransport protocolError = _ScriptedTransport(
    initializeError: <String, Object?>{'code': -32601, 'message': '方法不存在'},
  );
  final McpClient errClient =
      McpClient(transport: protocolError, serverName: 'err');
  final Object? protocolFailure = await _guard(() async {
    return <String, Object?>{'name': (await errClient.initialize()).name};
  });
  await errClient.close();

  // 场景 4：result 畸形（第二页回一个非对象 result）。
  final _ScriptedTransport malformed = _ScriptedTransport(
    initialize: <String, Object?>{'protocolVersion': kMcpProtocolVersion},
    pages: <Object?>[
      <String, Object?>{'tools': <Object?>[], 'nextCursor': 'c2'},
      '不是对象',
    ],
  );
  final McpClient malformedClient =
      McpClient(transport: malformed, serverName: 'mal');
  await malformedClient.initialize();
  final Object? malformedFailure = await _guard(() async {
    return <String, Object?>{'count': (await malformedClient.listTools()).length};
  });
  await malformedClient.close();

  // 场景 5：超时（服务端对 tools/list 不回应）。
  final _ScriptedTransport silent = _ScriptedTransport(
    initialize: <String, Object?>{'protocolVersion': kMcpProtocolVersion},
    silentMethods: <String>{'tools/list'},
  );
  final McpClient timeoutClient = McpClient(
    transport: silent,
    serverName: 'slow',
    timeout: const Duration(milliseconds: 5),
  );
  await timeoutClient.initialize();
  final Object? timeoutFailure = await _guard(() async {
    return <String, Object?>{'count': (await timeoutClient.listTools()).length};
  });
  await timeoutClient.close();

  // 场景 6：断连（连接级错误 → 在账请求判 disconnected，断连流触发一次）。
  final _ScriptedTransport dying = _ScriptedTransport(
    initialize: <String, Object?>{'protocolVersion': kMcpProtocolVersion},
    silentMethods: <String>{'tools/list'},
  );
  final McpClient disconnectClient =
      McpClient(transport: dying, serverName: 'dying');
  await disconnectClient.initialize();
  int disconnectSignals = 0;
  disconnectClient.disconnects.listen((_) => disconnectSignals += 1);
  final Future<List<McpTool>> pending = disconnectClient.listTools();
  // 守护要在触发故障**之前**建好：晚一步就成未处理异常（与 S17 的同款坑）。
  final Future<Object?> disconnectFailure = _guard(() async {
    return <String, Object?>{'count': (await pending).length};
  });
  await dying.fail(const McpException('server-exited', '子进程退出'));
  await disconnectFailure;
  await _pump();
  await disconnectClient.close();
  final Object? disconnectFailureValue = await disconnectFailure;
  final Map<String, Object?> disconnectCase = <String, Object?>{
    'pending': disconnectFailureValue,
    'disconnectSignals': disconnectSignals,
    'ready': disconnectClient.ready,
  };

  // 场景 7：close 之后剩余待办判 closed。
  final _ScriptedTransport hold = _ScriptedTransport(
    initialize: <String, Object?>{'protocolVersion': kMcpProtocolVersion},
    silentMethods: <String>{'tools/list'},
  );
  final McpClient closingClient = McpClient(transport: hold, serverName: 'hold');
  await closingClient.initialize();
  final Future<List<McpTool>> closingPending = closingClient.listTools();
  final Future<Object?> closedFailure = _guard(() async {
    return <String, Object?>{'count': (await closingPending).length};
  });
  await closingClient.close();
  await closedFailure;

  return <String, Object?>{
    'name': 'mcp-client',
    'kind': 'mcp-client',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'happy',
        'label': '完整链路：握手（服务端版本照收不误）→ 两页工具 → 调用 → 关闭（幂等）',
        'input': <String, Object?>{
          'serverName': 'fs',
          'initializeResult': <String, Object?>{
            'protocolVersion': '2024-11-05',
            'capabilities': <String, Object?>{},
            'serverInfo': <String, Object?>{'name': 'fake', 'version': '9.9'},
          },
          'pages': <Object?>[
            <String, Object?>{
              'tools': <Object?>[
                <String, Object?>{
                  'name': 'read_file',
                  'description': '读',
                  'inputSchema': <String, Object?>{'type': 'object'},
                },
              ],
              'nextCursor': 'c2',
            },
            <String, Object?>{
              'tools': <Object?>[
                <String, Object?>{'name': 'write_file', 'riskLevel': 'destructive'},
              ],
            },
          ],
          'callResult': <String, Object?>{
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'ok'},
            ],
            'structuredContent': <String, Object?>{'bytes': 12},
          },
        },
        'expect': happy,
      },
      <String, Object?>{
        'scenario': 'errors',
        'label': '失败收敛：翻页超限 / 协议错误 / result 畸形 / 超时 / 断连 / 关闭',
        'input': <String, Object?>{
          'loopingCursor': 'always-more',
          'initializeError': <String, Object?>{
            'code': -32601,
            'message': '方法不存在',
          },
          'malformedPage': '不是对象',
          'timeoutMs': 5,
          'disconnectCause': <String, Object?>{
            'code': 'server-exited',
            'message': '子进程退出',
          },
        },
        'expect': <String, Object?>{
          'tooManyPages': tooManyPages,
          'protocolError': protocolFailure,
          'malformedResult': malformedFailure,
          'timeout': timeoutFailure,
          'disconnect': disconnectCase,
          'closed': await closedFailure,
        },
      },
    ],
  };
}

/// close 幂等：第二次调用不应抛。
Future<bool> _doubleClose(McpClient client) async {
  try {
    await client.close();
    return true;
  } on Object {
    return false;
  }
}

/// 按方法自动应答的进程内假传输：记录发出的消息、模拟断连与畸形页。
class _ScriptedTransport implements McpTransport {
  _ScriptedTransport({
    this.initialize = const <String, Object?>{},
    this.initializeError,
    this.connectError,
    this.pages = const <Object?>[],
    this.callResult = const <String, Object?>{},
    this.silentMethods = const <String>{},
  });

  /// 非空时 `connect` 抛它（模拟连不上的服务端）。
  final McpException? connectError;

  /// `initialize` 的 `result`。
  final Map<String, Object?> initialize;

  /// 非空时 `initialize` 回失败响应。
  final Map<String, Object?>? initializeError;

  /// `tools/list` 的分页 `result`（按序消费；非对象形态直接放这里）。
  final List<Object?> pages;

  /// `tools/call` 的 `result`。
  final Map<String, Object?> callResult;

  /// 这些方法**不回应**（模拟哑巴服务端 / 断连前在账请求）。
  final Set<String> silentMethods;

  final StreamController<McpMessage> _incoming = StreamController<McpMessage>();
  final List<String> _sent = <String>[];
  int _nextId = 1;
  int _page = 0;
  bool _closed = true;

  /// 发出消息的标签序列（请求取方法名，通知也取方法名）。
  List<String> get sentLabels => List<String>.of(_sent);

  @override
  Stream<McpMessage> get messages => _incoming.stream;

  @override
  Stream<String> get diagnostics => const Stream<String>.empty();

  @override
  Future<void> connect() async {
    if (!_closed) return;
    final McpException? error = connectError;
    if (error != null) throw error;
    _closed = false;
  }

  @override
  Future<void> disconnect() async {
    _closed = true;
  }

  @override
  Future<void> send(McpMessage message) async {
    final String? method = message.method;
    _sent.add(method ?? 'response');
    if (message.notification) return;
    final Object? id = message.id;
    if (id == null || method == null) return;
    if (silentMethods.contains(method)) return;
    final Map<String, Object?> json = _replyFor(method, id);
    _incoming.add(McpMessage.fromJson(json));
  }

  Map<String, Object?> _replyFor(String method, Object id) {
    if (method == 'initialize') {
      final Map<String, Object?>? error = initializeError;
      if (error != null) {
        return <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'error': error,
        };
      }
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': initialize,
      };
    }
    if (method == 'tools/call') {
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': callResult,
      };
    }
    if (method == 'tools/list') {
      // 页用尽后重复最后一页：游标一直在 → 触发翻页上限。
      final Object? page =
          _page < pages.length ? pages[_page] : (pages.isEmpty ? null : pages.last);
      _page += 1;
      return <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': page,
      };
    }
    // 未知方法：回一个空 result（客户端不解析它）。
    return <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': <String, Object?>{},
    };
  }

  /// 注入连接级错误（模拟子进程退出 / SSE 结束）。
  Future<void> fail(Object error) async {
    if (_incoming.isClosed) return;
    _incoming.addError(error);
    await _incoming.close();
  }
}

// ───────────────────────────── 注册表 ─────────────────────────────

/// kind = mcp-registry：装配、断连注销、别名、关闭。
Future<Map<String, Object?>> _mcpRegistry() async {
  final Context ctx = Context.root();
  final ToolRegistry tools = provideTools(ctx);

  _RegistryFixture makeClient(String name, {bool connectFails = false}) {
    final _ScriptedTransport transport = _ScriptedTransport(
      connectError:
          connectFails ? McpException('not-connected', '连不上 $name') : null,
      initialize: <String, Object?>{'protocolVersion': kMcpProtocolVersion},
      pages: <Object?>[
        <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{
              'name': 'read_file',
              'description': '$name 的 read_file',
            },
            <String, Object?>{'name': 'write_file', 'riskLevel': 'destructive'},
          ],
        },
      ],
      callResult: <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '$name:ok'},
        ],
      },
    );
    return _RegistryFixture(
      client: McpClient(transport: transport, serverName: name),
      transport: transport,
    );
  }

  final McpRegistry registry = McpRegistry();

  final _RegistryFixture fs = makeClient('fs');
  await registry.attach(ctx, fs.client);
  final _RegistryFixture git = makeClient('git');
  await registry.attach(ctx, git.client);

  final Map<String, Object?> afterAttach = <String, Object?>{
    'servers': registry.servers,
    'tools': tools.names,
    'groups': <String, Object?>{
      for (final String name in tools.names) name: tools.get(name)?.group,
    },
    'risks': <String, Object?>{
      for (final String name in tools.names)
        name: tools.get(name)?.riskLevel.name,
    },
    'fsToolCount': registry.toolsOf('fs').length,
    'clientOfMissing': registry.clientOf('nope') != null,
  };

  // 装配一台连不上的 server：不上账（不留半死条目）。
  final _RegistryFixture broken = makeClient('broken', connectFails: true);
  final Object? attachFailure = await _guard(() async {
    await registry.attach(ctx, broken.client);
    return 'attached';
  });

  // 断连一台：只注销它的工具，另一台照常。
  await fs.transport.fail(const McpException('server-exited', '子进程退出'));
  await _pump();
  final Map<String, Object?> afterDrop = <String, Object?>{
    'servers': registry.servers,
    'tools': tools.names,
  };

  // 短别名。
  registry.addAlias(ctx, 'read_file', 'git__read_file');
  final Map<String, Object?> afterAlias = <String, Object?>{
    'tools': tools.names,
    'aliasDescription': tools.get('read_file')?.description,
    'aliasGroup': tools.get('read_file')?.group,
    'aliasRisk': tools.get('read_file')?.riskLevel.name,
    'aliasSchemaName': tools.get('read_file')?.toSchema()['name'],
  };
  final Object? aliasMissing = await _guard(() async {
    registry.addAlias(ctx, 'nope', 'missing__tool');
    return 'added';
  });
  final Object? aliasClash = await _guard(() async {
    registry.addAlias(ctx, 'git__read_file', 'git__read_file');
    return 'added';
  });

  // 同名重复装配。
  final Object? duplicate = await _guard(() async {
    await registry.attach(ctx, makeClient('git').client);
    return 'attached';
  });

  // 全部关闭：幂等。
  await registry.close();
  await registry.close();
  final Map<String, Object?> afterClose = <String, Object?>{
    'servers': registry.servers,
    'tools': tools.names,
  };

  // 上下文释放：撤销句柄幂等，不应抛。
  final Context other = Context.root();
  final ToolRegistry otherTools = provideTools(other);
  final _RegistryFixture late = makeClient('late');
  await registry.attach(other, late.client);
  final int beforeDispose = otherTools.names.length;
  other.dispose();
  Object? disposeFailure;
  try {
    other.dispose();
  } on Object catch (error) {
    disposeFailure = '$error';
  }
  ctx.dispose();

  return <String, Object?>{
    'name': 'mcp-registry',
    'kind': 'mcp-registry',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'lifecycle',
        'label': '注册表生命周期：装配上账、失败不上账、断连只注销本 server、短别名、重复装配被拒、关闭幂等',
        'input': <String, Object?>{'servers': <String>['fs', 'git', 'broken']},
        'expect': <String, Object?>{
          'afterAttach': afterAttach,
          'attachFailure': attachFailure,
          'afterDrop': afterDrop,
          'afterAlias': afterAlias,
          'aliasMissing': aliasMissing,
          'aliasClash': aliasClash,
          'duplicate': duplicate,
          'afterClose': afterClose,
          'contextDispose': <String, Object?>{
            'registeredBefore': beforeDispose,
            'registeredAfter': otherTools.names.length,
            'secondDisposeFailed': disposeFailure,
          },
        },
      },
    ],
  };
}

/// 让微任务队列跑完（断连信号是异步投递的）。
Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

/// 注册表用例里的一台 server（客户端 + 传输）。
class _RegistryFixture {
  _RegistryFixture({required this.client, required this.transport});

  final McpClient client;
  final _ScriptedTransport transport;
}
