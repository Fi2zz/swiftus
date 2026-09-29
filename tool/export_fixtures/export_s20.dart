// S20 联网搜索与抓取 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 用例自带输入：请求形状、响应体、凭据表、provider 序列、链接都写进 `input`，
// 运行器据此驱动替身——输入藏在导出器里等于把 fixture 与导出器绑死。
//
// 归一化（S20 专用）：
// - **查询项投影解码后的值**（不投原始 URL 串）：Dart 的 `Uri.queryParameters` 与
//   Swift 的 `URLComponents.queryItems` 在 `+` / `%20` 上不完全一致，逐字比 URL 会把
//   用例绑死在编码细节上；方法 / 主机 / 路径 / 头名（小写）/ 体这些语义面才进 fixture；
// - **头名小写后排序**（Dart 的 `http.Headers` 大小写不敏感，投原始大小写两端不可比）；
// - **不含任何时间语义**：本规格没有墙钟与时区，故不需要钉 TZ（与 S9 不同）。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_core/conatus_core.dart';
import 'package:conatus_credentials/conatus_credentials.dart';
import 'package:conatus_foundation/conatus_foundation.dart';
import 'package:conatus_search/conatus_search.dart';
// stripMarkup 未从包门面导出（只有 stripHtml 导出了），标记清洗是要锁的语义，
// 故直接引 src（Dart 不禁止跨包引 src）。
import 'package:conatus_search/src/search_markup.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Future<Map<String, Object?>> Function()> fixtures =
      <String, Future<Map<String, Object?>> Function()>{
    'search-service': _searchService,
    'search-registry': _searchRegistry,
    'search-markup': _searchMarkup,
    'search-providers': _searchProviders,
    'search-fetch': _searchFetch,
    'search-web-tools': _searchWebTools,
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
  return Directory('${here.parent.parent.path}/spec/fixtures/s20');
}

/// 记录的请求（形状投影用）。
class _Capture {
  _Capture(this.response, {this.status = 200});

  final String response;
  final int status;
  http.BaseRequest? request;

  // 响应体一律走 utf8 字节：`http.Response(String, …)` 默认按 latin1 编码，
  // 中文 fixture 会直接抛「Contains invalid characters」。
  MockClient get client => MockClient((http.Request request) async {
        this.request = request;
        if (status == 0) throw http.ClientException('network down');
        return http.Response.bytes(
          utf8.encode(response),
          status,
          headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
        );
      });
}

/// 请求形状投影：方法 / 主机 / 路径 / 头名（小写、排序）/ 解码后的查询项 / 体。
Map<String, Object?> _shape(http.BaseRequest? request) {
  if (request == null) return <String, Object?>{'sent': false};
  final Uri uri = request.url;
  final Map<String, Object?> query = <String, Object?>{};
  uri.queryParametersAll.forEach((String key, List<String> values) {
    query[key] = values.length == 1 ? values.first : values;
  });
  final Map<String, Object?> shape = <String, Object?>{
    'sent': true,
    'method': request.method,
    'host': uri.host,
    'path': uri.path,
    'query': query,
  };
  final Map<String, String> headers = <String, String>{};
  request.headers.forEach((String key, String value) {
    headers[key.toLowerCase()] = value;
  });
  final List<String> names = headers.keys.toList()..sort();
  shape['headerNames'] = names;
  if (names.contains('authorization') || names.contains('x-api-key')) {
    shape['authHeader'] = headers['authorization'] ?? headers['x-api-key'];
  }
  if (names.contains('x-subscription-token')) {
    shape['authHeader'] = headers['x-subscription-token'];
  }
  if (names.contains('user-agent')) {
    // UA 是浏览器指纹，两端不必逐字一致：只断言「有 UA」。
    shape['hasUserAgent'] = true;
  }
  if (request is http.Request) {
    final String body = (request as http.Request).body;
    if (body.isNotEmpty) shape['body'] = jsonDecode(body);
  }
  return shape;
}

/// 一次查询的投影。
Map<String, Object?> _results(List<SearchResult> results) => <String, Object?>{
      'results': <Object?>[
        for (final SearchResult r in results) r.toJson(),
      ],
    };

/// 尽力执行并把异常收敛成 `{error: 消息}`。
///
/// `prefix` 非空时改为投影 `errorPrefix`（只断言消息前缀）——用于原因文本属语言
/// 相关运行时描述的形态（见 `networkPrefix` 用例）。
Future<Object?> _guard(
  Future<Object?> Function() body, {
  String? prefix,
}) async {
  try {
    return await body();
  } on SearchException catch (error) {
    return prefix == null
        ? <String, Object?>{'error': error.message}
        : <String, Object?>{'errorPrefix': prefix};
  } on FetchException catch (error) {
    return prefix == null
        ? <String, Object?>{'error': error.message}
        : <String, Object?>{'errorPrefix': prefix};
  } on Object catch (error) {
    return <String, Object?>{'unexpected': '$error'};
  }
}

// ───────────────────────────── 服务与回退链 ─────────────────────────────

/// 脚本化 provider：按输入决定返回还是抛错。
class _ScriptedProvider implements SearchProvider {
  _ScriptedProvider(this.name, this.spec);

  @override
  final String name;
  final Map<String, Object?> spec;

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    if (spec['fails'] == true) {
      throw SearchException(spec['error'] as String? ?? 'boom');
    }
    final List<Object?> items =
        spec['results'] as List<Object?>? ?? const <Object?>[];
    return <SearchResult>[
      for (final Object? raw in items)
        SearchResult(
          title: (raw! as Map<String, Object?>)['title'] as String? ?? '',
          url: (raw as Map<String, Object?>)['url'] as String? ?? '',
          snippet: (raw as Map<String, Object?>)['snippet'] as String? ?? '',
        ),
    ];
  }
}

SearchProvider _provider(Map<String, Object?> spec) =>
    _ScriptedProvider(spec['name']! as String, spec);

/// 把 provider 列表（fixture 的 `providers` 字段）注册进服务。
SearchService _service(List<Object?> providers, {List<Object?>? statuses}) {
  final SearchService service = SearchService(
    statuses: <SearchSourceStatus>[
      for (final Object? raw in statuses ?? const <Object?>[])
        SearchSourceStatus(
          name: (raw! as Map<String, Object?>)['name']! as String,
          available: (raw as Map<String, Object?>)['available'] == true,
          reason: (raw as Map<String, Object?>)['reason'] as String? ?? '',
        ),
    ],
  );
  for (final Object? spec in providers) {
    service.register(_provider(spec! as Map<String, Object?>));
  }
  return service;
}

/// kind = search-service：注册/撤销、顺序回退、显式路由、错误文案逐字。
Future<Map<String, Object?>> _searchService() async {
  const List<Object?> providers = <Object?>[
    <String, Object?>{'name': 'a', 'fails': true, 'error': 'boom'},
    <String, Object?>{
      'name': 'b',
      'results': <Object?>[
        <String, Object?>{'title': 'T', 'url': 'https://example.com', 'snippet': 'S'},
      ],
    },
  ];
  // 空结果算成功：后面的 provider 不再被尝试。
  const List<Object?> emptyThenHit = <Object?>[
    <String, Object?>{'name': 'a', 'results': <Object?>[]},
    <String, Object?>{
      'name': 'b',
      'results': <Object?>[
        <String, Object?>{'title': 'T', 'url': 'https://example.com', 'snippet': 'S'},
      ],
    },
  ];
  const List<Object?> allFail = <Object?>[
    <String, Object?>{'name': 'a', 'fails': true, 'error': 'boom'},
    <String, Object?>{'name': 'b', 'fails': true, 'error': 'HTTP 500'},
  ];

  final SearchService main = _service(providers);
  final Map<String, Object?> registry = <String, Object?>{
    'names': <String>[
      for (final SearchProvider p in main.providers) p.name,
    ],
    'foundA': main.get('a') != null,
    'foundMissing': main.get('nope') != null,
  };
  // 撤销：返回的函数幂等。
  final SearchService revocable = _service(providers);
  final Disposer off = revocable.register(_provider(<String, Object?>{'name': 'c'}));
  off();
  off();
  registry['afterOff'] = <String>[
    for (final SearchProvider p in revocable.providers) p.name,
  ];

  final Map<String, Object?> fallback = <String, Object?>{
    'firstSuccess': _results(await main.search('q')),
    'emptyIsSuccess':
        _results(await _service(emptyThenHit).search('q')),
    'emptySkipsNext': <String>[
      for (final SearchProvider p in _service(emptyThenHit).providers) p.name,
    ],
    'allFailed': await _guard(() async {
      return _results(await _service(allFail).search('q'));
    }),
    'explicitProvider':
        _results(await main.search('q', provider: 'b')),
    'explicitFailing': await _guard(() async {
      return _results(await main.search('q', provider: 'a'));
    }),
    'unregistered': await _guard(() async {
      return _results(await main.search('q', provider: 'z'));
    }),
    'noProvider': await _guard(() async {
      return _results(await SearchService().search('q'));
    }),
  };

  return <String, Object?>{
    'name': 'search-service',
    'kind': 'search-service',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'registry',
        'label': '注册表：按注册顺序列出、get 未注册返回空、撤销幂等',
        'input': <String, Object?>{'providers': providers},
        'expect': registry,
      },
      <String, Object?>{
        'scenario': 'fallback',
        'label': '顺序回退：首个不抛异常即返回（含空列表）、全部失败聚合文案、显式路由',
        'input': <String, Object?>{
          'providers': providers,
          'emptyThenHit': emptyThenHit,
          'allFail': allFail,
        },
        'expect': fallback,
      },
    ],
  };
}

// ───────────────────────────── 装配 ─────────────────────────────

/// kind = search-registry：按 order 构造、跳过原因、显式 providers 覆盖。
Future<Map<String, Object?>> _searchRegistry() async {
  List<Object?> namesOf(SearchProviderSet set) =>
      <String>[for (final SearchProvider p in set.providers) p.name];
  List<Object?> statusShape(SearchProviderSet set) => <Object?>[
        for (final SearchSourceStatus s in set.statuses)
          <String, Object?>{
            'name': s.name,
            'available': s.available,
            'reason': s.reason,
          },
      ];

  final InMemoryCredentials onlyTavily = InMemoryCredentials(
    initial: <String, String>{'TAVILY_API_KEY': 't'},
  );
  final InMemoryCredentials exaAndBrave = InMemoryCredentials(
    initial: <String, String>{'EXA_API_KEY': 'e', 'BRAVE_API_KEY': 'b'},
  );
  final InMemoryCredentials empty = InMemoryCredentials();

  // 1) 缺 Key 的源跳过并记原因（含键名）。
  final SearchProviderSet missing = buildSearchProviders(
    order: kDefaultSearchOrder,
    credentials: onlyTavily,
  );
  // 2) order 覆盖默认顺序，未列出的源连状态都不出现。
  final SearchProviderSet reordered = buildSearchProviders(
    order: <String>['duckduckgo', 'exa'],
    credentials: exaAndBrave,
  );
  // 3) 未知名字记为不可用。
  final SearchProviderSet unknown = buildSearchProviders(
    order: <String>['nope', 'duckduckgo'],
    credentials: empty,
  );
  // 4) 免 Key 源始终可用。
  final SearchProviderSet keyless = buildSearchProviders(
    order: <String>['duckduckgo'],
    credentials: empty,
  );
  // 5) 内置表形状。
  final Map<String, Object?> table = <String, Object?>{
    'names': kSearchProviderSpecs.keys.toList()..sort(),
    'credentialKeys': <String, Object?>{
      for (final String name in kSearchProviderSpecs.keys)
        name: kSearchProviderSpecs[name]!.credentialKey,
    },
    'defaultOrder': kDefaultSearchOrder,
  };

  // 无凭据服务：只装配免 Key 源，其余记「未提供凭据服务」。
  final Context noCreds = Context.root();
  final SearchService noCredsService = provideSearch(noCreds);
  final Map<String, Object?> keylessAssembly = <String, Object?>{
    'providers': namesOf(SearchProviderSet(providers: noCredsService.providers, statuses: const <SearchSourceStatus>[])),
    'statuses': statusShape(SearchProviderSet(
      providers: noCredsService.providers,
      statuses: noCredsService.statuses,
    )),
  };
  noCreds.dispose();
  final Map<String, Object?> afterDispose = <String, Object?>{
    'providers': noCredsService.providers.length,
  };

  // 显式 credentials 决定可用源；缺省取上下文服务。
  final Context explicit = Context.root();
  final SearchService explicitService = provideSearch(
    explicit,
    credentials: InMemoryCredentials(initial: <String, String>{'EXA_API_KEY': 'e'}),
  );
  final Map<String, Object?> explicitAssembly = <String, Object?>{
    'providers': <String>[
      for (final SearchProvider p in explicitService.providers) p.name,
    ],
    'statuses': statusShape(SearchProviderSet(
      providers: explicitService.providers,
      statuses: explicitService.statuses,
    )),
  };
  explicit.dispose();

  final Context fromCtx = Context.root();
  provideCredentials(
    fromCtx,
    credentials: InMemoryCredentials(initial: <String, String>{'BRAVE_API_KEY': 'b'}),
  );
  final SearchService fromCtxService = provideSearch(fromCtx);
  final Map<String, Object?> ctxAssembly = <String, Object?>{
    'providers': <String>[
      for (final SearchProvider p in fromCtxService.providers) p.name,
    ],
  };
  fromCtx.dispose();

  // 显式 providers 忽略 order，statuses 为空。
  final Context scripted = Context.root();
  final SearchService scriptedService = provideSearch(
    scripted,
    providers: <SearchProvider>[_provider(<String, Object?>{'name': 'x'})],
    order: <String>['tavily'],
    credentials: onlyTavily,
  );
  final Map<String, Object?> explicitProviders = <String, Object?>{
    'providers': <String>[
      for (final SearchProvider p in scriptedService.providers) p.name,
    ],
    'statuses': scriptedService.statuses.length,
  };
  scripted.dispose();

  return <String, Object?>{
    'name': 'search-registry',
    'kind': 'search-registry',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'table',
        'label': '内置源表：四个源、duckduckgo 免 Key、缺省顺序',
        'input': <String, Object?>{},
        'expect': table,
      },
      <String, Object?>{
        'scenario': 'build',
        'label': '按 order 构造：缺 Key 跳过并记「缺少 <KEY>」、order 决定顺序、未知源记原因、免 Key 始终可用',
        'input': <String, Object?>{
          'credentials': <String, Object?>{
            'missing': <String, String>{'TAVILY_API_KEY': 't'},
            'reordered': <String, String>{'EXA_API_KEY': 'e', 'BRAVE_API_KEY': 'b'},
            'empty': <String, String>{},
          },
          'orders': <String, Object?>{
            'missing': kDefaultSearchOrder,
            'reordered': <String>['duckduckgo', 'exa'],
            'unknown': <String>['nope', 'duckduckgo'],
            'keyless': <String>['duckduckgo'],
          },
        },
        'expect': <String, Object?>{
          'missingProviders': namesOf(missing),
          'missingStatuses': statusShape(missing),
          'reorderedProviders': namesOf(reordered),
          'reorderedStatuses': statusShape(reordered),
          'unknownProviders': namesOf(unknown),
          'unknownStatuses': statusShape(unknown),
          'keylessProviders': namesOf(keyless),
          'keylessStatuses': statusShape(keyless),
        },
      },
      <String, Object?>{
        'scenario': 'assemble',
        'label': 'provideSearch：无凭据服务只装配 duckduckgo、显式/上下文凭据、显式 providers 忽略 order、上下文释放撤销注册',
        'input': <String, Object?>{
          'order': kDefaultSearchOrder,
          'noCredentials': true,
          'explicit': <String, String>{'EXA_API_KEY': 'e'},
          'fromContext': <String, String>{'BRAVE_API_KEY': 'b'},
        },
        'expect': <String, Object?>{
          'noCredentials': keylessAssembly,
          'afterDispose': afterDispose,
          'explicit': explicitAssembly,
          'fromContext': ctxAssembly,
          'explicitProviders': explicitProviders,
        },
      },
    ],
  };
}

// ───────────────────────────── 标记清洗与 HTML 解析 ─────────────────────────────

/// kind = search-markup：stripMarkup / stripHtml / parseDuckDuckGoHtml。
Future<Map<String, Object?>> _searchMarkup() async {
  List<Object?> markupCases() => <Object?>[
        <String, Object?>{
          'input': '<strong>粗体</strong> &amp; <em>斜体</em>',
          'expect': stripMarkup('<strong>粗体</strong> &amp; <em>斜体</em>'),
        },
        <String, Object?>{
          'input': '&lt;tag&gt; &quot;q&quot; &#39;s&#39; &nbsp;x&nbsp;',
          'expect': stripMarkup('&lt;tag&gt; &quot;q&quot; &#39;s&#39; &nbsp;x&nbsp;'),
        },
        <String, Object?>{
          'input': '  <a href="/x">链接</a>  ',
          'expect': stripMarkup('  <a href="/x">链接</a>  '),
        },
        <String, Object?>{'input': '', 'expect': stripMarkup('')},
        <String, Object?>{'input': '没有标记的纯文本', 'expect': stripMarkup('没有标记的纯文本')},
      ];

  List<Object?> htmlCases() => <Object?>[
        <String, Object?>{
          'input': '<html><body><script>bad()</script><p>Hello &amp; world</p></body></html>',
          'expect': stripHtml(
              '<html><body><script>bad()</script><p>Hello &amp; world</p></body></html>'),
        },
        <String, Object?>{
          'input': '<style>a{color:red}</style><p>正文</p>',
          'expect': stripHtml('<style>a{color:red}</style><p>正文</p>'),
        },
        // 标签替换成空格（不是删空）：相邻标签之间不粘连。
        <String, Object?>{
          'input': '<p>a</p><p>b</p>',
          'expect': stripHtml('<p>a</p><p>b</p>'),
        },
        // 空白压缩：换行与连续空格收成单空格。
        <String, Object?>{
          'input': '<p>多  行\n\t文本</p>',
          'expect': stripHtml('<p>多  行\n\t文本</p>'),
        },
        <String, Object?>{'input': '', 'expect': stripHtml('')},
      ];

  const String ddgHtml = '''
<div class="result">
  <a rel="nofollow" class="result__a"
     href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example <b>A</b></a>
  <a class="result__snippet">First &amp; snippet</a>
</div>
<div class="result">
  <a rel="nofollow" class="result__a" href="https://example.org/b">Example B</a>
  <a class="result__snippet">Second</a>
</div>
''';
  // 标题或链接为空 → 跳过该条；越界摘要 → 空串；limit 截断。
  const String ddgEdge = '''
<a class="result__a" href="https://example.com/ok">OK</a>
<a class="result__a" href="">无链接</a>
<a class="result__a" href="https://example.com/keep">有标题</a>
''';

  return <String, Object?>{
    'name': 'search-markup',
    'kind': 'search-markup',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'strip-markup',
        'label': '去标签 + 解实体 + trim（snippet 会原样进模型可见输出）',
        'input': markupCases(),
        'expect': markupCases(),
      },
      <String, Object?>{
        'scenario': 'strip-html',
        'label': '去 script/style 块、标签换空格、解实体、压缩空白',
        'input': htmlCases(),
        'expect': htmlCases(),
      },
      <String, Object?>{
        'scenario': 'duckduckgo-parse',
        'label': 'DuckDuckGo HTML 解析：uddg 跳转解码、按序配对、空项跳过、limit 截断',
        'input': <String, Object?>{
          'cases': <Object?>[
            <String, Object?>{'html': ddgHtml, 'limit': 5},
            <String, Object?>{'html': ddgHtml, 'limit': 1},
            <String, Object?>{'html': ddgEdge, 'limit': 5},
            <String, Object?>{'html': '<html></html>', 'limit': 5},
          ],
        },
        'expect': <Object?>[
          _results(parseDuckDuckGoHtml(ddgHtml, limit: 5)),
          _results(parseDuckDuckGoHtml(ddgHtml, limit: 1)),
          _results(parseDuckDuckGoHtml(ddgEdge, limit: 5)),
          _results(parseDuckDuckGoHtml('<html></html>', limit: 5)),
        ],
      },
    ],
  };
}

// ───────────────────────────── provider 协议 ─────────────────────────────

/// kind = search-providers：请求形状与响应解析（四个 provider）。
Future<Map<String, Object?>> _searchProviders() async {
  const String endpoint = 'https://probe.test/search';

  // tavily：POST + bearer + body；解析 results[].content。
  final _Capture tavilyOk = _Capture(
    jsonEncode(<String, Object?>{
      'results': <Object?>[
        <String, Object?>{
          'title': 'T1',
          'url': 'https://example.com/1',
          'content': '正文 <b>一</b>',
        },
      ],
    }),
  );
  final Map<String, Object?> tavily = <String, Object?>{
    'name': TavilySearchProvider(apiKey: 'k', client: tavilyOk.client, endpoint: Uri.parse(endpoint)).name,
    'shape': _shape(
        (await TavilySearchProvider(apiKey: 'k', client: tavilyOk.client, endpoint: Uri.parse(endpoint)).search('swift 编程', limit: 99))
            .isEmpty
        ? tavilyOk.request
        : tavilyOk.request),
    'results': _results(await TavilySearchProvider(
            apiKey: 'k', client: tavilyOk.client, endpoint: Uri.parse(endpoint))
        .search('swift 编程', limit: 99)),
    'httpError': await _guard(() async {
      final _Capture c = _Capture('nope', status: 503);
      return _results(await TavilySearchProvider(
              apiKey: 'k', client: c.client, endpoint: Uri.parse(endpoint))
          .search('q'));
    }),
    'badJson': await _guard(() async {
      final _Capture c = _Capture('[1,2]');
      return _results(await TavilySearchProvider(
              apiKey: 'k', client: c.client, endpoint: Uri.parse(endpoint))
          .search('q'));
    }),
  };

  // exa：POST + x-api-key；text 缺失回落 summary。
  final _Capture exaOk = _Capture(
    jsonEncode(<String, Object?>{
      'results': <Object?>[
        <String, Object?>{'title': 'E1', 'url': 'https://example.com/e', 'text': '长文本'},
        <String, Object?>{'title': 'E2', 'url': 'https://example.com/e2', 'summary': '摘要'},
        <String, Object?>{'url': 'https://example.com/e3'},
      ],
    }),
  );
  final ExaSearchProvider exa =
      ExaSearchProvider(apiKey: 'k2', client: exaOk.client, endpoint: Uri.parse(endpoint));
  final Map<String, Object?> exaShape = <String, Object?>{
    'name': exa.name,
    'shape': _shape((await exa.search('q', limit: 3)).isEmpty ? null : exaOk.request),
    'results': _results(await exa.search('q', limit: 3)),
  };

  // brave：GET + query + x-subscription-token；description 经 stripMarkup。
  final _Capture braveOk = _Capture(
    jsonEncode(<String, Object?>{
      'web': <String, Object?>{
        'results': <Object?>[
          <String, Object?>{
            'title': 'B1',
            'url': 'https://example.com/b',
            'description': '摘要 <b>粗</b> &amp; more',
          },
        ],
      },
    }),
  );
  final BraveSearchProvider brave = BraveSearchProvider(
      apiKey: 'k3', client: braveOk.client, endpoint: Uri.parse(endpoint));
  final Map<String, Object?> braveShape = <String, Object?>{
    'name': brave.name,
    'shape': _shape((await brave.search('swift 编程', limit: 99)).isEmpty ? null : braveOk.request),
    'results': _results(await brave.search('swift 编程', limit: 99)),
    'noWebKey': _results(await BraveSearchProvider(
            apiKey: 'k3',
            client: _Capture(jsonEncode(<String, Object?>{'other': true})).client,
            endpoint: Uri.parse(endpoint))
        .search('q')),
  };

  // duckduckgo：GET + UA；html 解析。
  final _Capture ddgOk = _Capture(
    '<a class="result__a" href="https://example.com/d">D <b>1</b></a>'
    '<a class="result__snippet">摘要 &amp; 一</a>',
  );
  final DuckDuckGoSearchProvider ddg = DuckDuckGoSearchProvider(
      client: ddgOk.client, endpoint: Uri.parse(endpoint));
  final Map<String, Object?> ddgShape = <String, Object?>{
    'name': ddg.name,
    'shape': _shape((await ddg.search('q')).isEmpty ? null : ddgOk.request),
    'results': _results(await ddg.search('q')),
    'httpError': await _guard(() async {
      final _Capture c = _Capture('nope', status: 503);
      return _results(await DuckDuckGoSearchProvider(
              client: c.client, endpoint: Uri.parse(endpoint))
          .search('q'));
    }),
  };

  return <String, Object?>{
    'name': 'search-providers',
    'kind': 'search-providers',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'tavily',
        'label': 'tavily：POST + bearer + body 形状、results[].content、非 200 / 非对象 JSON',
        'input': <String, Object?>{
          'endpoint': endpoint,
          'query': 'swift 编程',
          'limit': 99,
          'apiKey': 'k',
          'responses': <Object?>[
            <String, Object?>{
              'status': 200,
              'body': jsonEncode(<String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'title': 'T1',
                    'url': 'https://example.com/1',
                    'content': '正文 <b>一</b>',
                  },
                ],
              }),
            },
            <String, Object?>{'status': 503, 'body': 'nope'},
            <String, Object?>{'status': 200, 'body': '[1,2]'},
          ],
        },
        'expect': tavily,
      },
      <String, Object?>{
        'scenario': 'exa',
        'label': 'exa：POST + x-api-key + contents 形状、text 缺失回落 summary、缺字段降级空串',
        'input': <String, Object?>{
          'endpoint': endpoint,
          'query': 'q',
          'limit': 3,
          'apiKey': 'k2',
          'response': <String, Object?>{
            'status': 200,
            'body': jsonEncode(<String, Object?>{
              'results': <Object?>[
                <String, Object?>{'title': 'E1', 'url': 'https://example.com/e', 'text': '长文本'},
                <String, Object?>{'title': 'E2', 'url': 'https://example.com/e2', 'summary': '摘要'},
                <String, Object?>{'url': 'https://example.com/e3'},
              ],
            }),
          },
        },
        'expect': exaShape,
      },
      <String, Object?>{
        'scenario': 'brave',
        'label': 'brave：GET 查询项 + x-subscription-token、description 清洗、缺 web 键返回空',
        'input': <String, Object?>{
          'endpoint': endpoint,
          'query': 'swift 编程',
          'limit': 99,
          'apiKey': 'k3',
          'response': <String, Object?>{
            'status': 200,
            'body': jsonEncode(<String, Object?>{
              'web': <String, Object?>{
                'results': <Object?>[
                  <String, Object?>{
                    'title': 'B1',
                    'url': 'https://example.com/b',
                    'description': '摘要 <b>粗</b> &amp; more',
                  },
                ],
              },
            }),
          },
          'noWebKeyResponse': <String, Object?>{
            'status': 200,
            'body': jsonEncode(<String, Object?>{'other': true}),
          },
        },
        'expect': braveShape,
      },
      <String, Object?>{
        'scenario': 'duckduckgo',
        'label': 'duckduckgo：GET + UA、html 解析、非 200',
        'input': <String, Object?>{
          'endpoint': endpoint,
          'query': 'q',
          'response': <String, Object?>{
            'status': 200,
            'body': '<a class="result__a" href="https://example.com/d">D <b>1</b></a>'
                '<a class="result__snippet">摘要 &amp; 一</a>',
          },
          'errorResponse': <String, Object?>{'status': 503, 'body': 'nope'},
        },
        'expect': ddgShape,
      },
    ],
  };
}

// ───────────────────────────── 抓取 ─────────────────────────────

/// kind = search-fetch：两个后端的成功与失败形态、截断。
Future<Map<String, Object?>> _searchFetch() async {
  const String endpoint = 'https://probe.test/scrape';
  const String page = 'https://example.com/post';

  final _Capture httpOk =
      _Capture('<html><body><script>bad()</script><p>Hello &amp; world</p></body></html>');
  final HttpFetcher http = HttpFetcher(client: httpOk.client);
  final Map<String, Object?> httpShape = <String, Object?>{
    'page': <String, Object?>{
      'url': (await http.fetch(page)).url,
      'content': (await http.fetch(page)).content,
      'format': (await http.fetch(page)).format.name,
    },
    'shape': _shape(httpOk.request),
    'truncated': (await http.fetch(page, maxChars: 5)).content,
  };

  final Map<String, Object?> httpErrors = <String, Object?>{
    'noHost': await _guard(() async => (await http.fetch('not a url')).content),
    'noHostWithScheme': await _guard(() async => (await http.fetch('https://')).content),
    'http404': await _guard(() async {
      final _Capture c = _Capture('', status: 404);
      return (await HttpFetcher(client: c.client).fetch(page)).content;
    }),
    // 传输层失败的原因文本是运行时的语言相关描述（Dart 的 ClientException /
    // IOException 文案 vs Foundation 的 localizedDescription），只投影前缀。
    // 传输失败：只断言前缀，原因文本是语言相关的运行时描述。
    'network': await _guard(() async {
      final _Capture c = _Capture('', status: 0);
      return (await HttpFetcher(client: c.client).fetch(page)).content;
    }, prefix: '抓取失败：'),
  };

  final _Capture fcOk = _Capture(jsonEncode(<String, Object?>{
    'success': true,
    'data': <String, Object?>{'markdown': '# 标题\n\n正文'},
  }));
  final FirecrawlFetcher firecrawl =
      FirecrawlFetcher(apiKey: 'f', client: fcOk.client, endpoint: Uri.parse(endpoint));
  final Map<String, Object?> firecrawlShape = <String, Object?>{
    'page': <String, Object?>{
      'url': (await firecrawl.fetch(page)).url,
      'content': (await firecrawl.fetch(page)).content,
      'format': (await firecrawl.fetch(page)).format.name,
    },
    'shape': _shape(fcOk.request),
    'truncated': (await firecrawl.fetch(page, maxChars: 3)).content,
  };

  final Map<String, Object?> firecrawlErrors = <String, Object?>{
    'http500': await _guard(() async {
      final _Capture c = _Capture('', status: 500);
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'notJson': await _guard(() async {
      final _Capture c = _Capture('<html>502</html>');
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'notObject': await _guard(() async {
      final _Capture c = _Capture('[1,2]');
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'successFalse': await _guard(() async {
      final _Capture c = _Capture(
          jsonEncode(<String, Object?>{'success': false, 'error': 'blocked'}));
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'successFalseNoError': await _guard(() async {
      final _Capture c = _Capture(jsonEncode(<String, Object?>{'success': false}));
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'noData': await _guard(() async {
      final _Capture c = _Capture(jsonEncode(<String, Object?>{'success': true}));
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'markdownMissing': <String, Object?>{
      'content': (await FirecrawlFetcher(
              apiKey: 'f',
              client: _Capture(jsonEncode(<String, Object?>{
                'success': true,
                'data': <String, Object?>{'other': 1},
              })).client,
              endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content,
    },
    'markdownNotString': await _guard(() async {
      final _Capture c = _Capture(jsonEncode(<String, Object?>{
        'success': true,
        'data': <String, Object?>{'markdown': 42},
      }));
      return (await FirecrawlFetcher(
              apiKey: 'f', client: c.client, endpoint: Uri.parse(endpoint))
          .fetch(page))
          .content;
    }),
    'noHost': await _guard(() async => (await firecrawl.fetch('ftp://x/y')).content),
  };
  firecrawlErrors['credentialKey'] = kFirecrawlCredentialKey;

  return <String, Object?>{
    'name': 'search-fetch',
    'kind': 'search-fetch',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'http',
        'label': 'HttpFetcher：GET 去标签取正文、maxChars 截断、链接校验 / 非 200 / 传输失败归一',
        'input': <String, Object?>{
          'page': page,
          'response': <String, Object?>{
            'status': 200,
            'body': '<html><body><script>bad()</script><p>Hello &amp; world</p></body></html>',
          },
          'maxChars': 5,
          'errors': <String, Object?>{
            'noHost': 'not a url',
            'noHostWithScheme': 'https://',
            'http404': <String, Object?>{'status': 404, 'body': ''},
            // 传输失败：只投影前缀（原因文本是语言相关的运行时描述）
            'network': <String, Object?>{'networkError': true},
          },
        },
        'expect': <String, Object?>{
          'ok': httpShape,
          'errors': httpErrors,
        },
      },
      <String, Object?>{
        'scenario': 'firecrawl',
        'label': 'FirecrawlFetcher：POST 形状取 markdown、六种失败形态各自文案',
        'input': <String, Object?>{
          'page': page,
          'endpoint': endpoint,
          'apiKey': 'f',
          'response': <String, Object?>{
            'status': 200,
            'body': '{"success":true,"data":{"markdown":"# 标题\\n\\n正文"}}',
          },
          'maxChars': 3,
          'errors': <String, Object?>{
            'http500': <String, Object?>{'status': 500, 'body': ''},
            'notJson': <String, Object?>{'status': 200, 'body': '<html>502</html>'},
            'notObject': <String, Object?>{'status': 200, 'body': '[1,2]'},
            'successFalse': <String, Object?>{'status': 200, 'body': '{"success":false,"error":"blocked"}'},
            'successFalseNoError': <String, Object?>{'status': 200, 'body': '{"success":false}'},
            'noData': <String, Object?>{'status': 200, 'body': '{"success":true}'},
            'markdownMissing': <String, Object?>{
              'status': 200,
              'body': '{"success":true,"data":{"other":1}}',
            },
            'markdownNotString': <String, Object?>{
              'status': 200,
              'body': '{"success":true,"data":{"markdown":42}}',
            },
            'noHost': 'ftp://x/y',
          },
        },
        'expect': <String, Object?>{
          'ok': firecrawlShape,
          'errors': firecrawlErrors,
          'credentialKey': kFirecrawlCredentialKey,
        },
      },
    ],
  };
}

// ───────────────────────────── 工具 ─────────────────────────────

/// kind = search-web-tools：两个工具的成功文本 / 失败码。
Future<Map<String, Object?>> _searchWebTools() async {
  // 搜索成功：文本形态与结构化值。
  final SearchService hit = _service(<Object?>[
    <String, Object?>{
      'name': 'a',
      'results': <Object?>[
        <String, Object?>{'title': '标题一', 'url': 'https://a.example/1', 'snippet': '摘要一'},
        <String, Object?>{'title': '标题二', 'url': 'https://a.example/2'},
      ],
    },
  ]);
  final ToolContext emptyCtx = ToolContext(
    const ToolCall(name: 'web_search', callId: 'c1', arguments: <String, Object?>{'query': 'swift'}),
  );
  final ToolResult hitResult = await WebSearchTool(search: hit).call(emptyCtx);

  final SearchService noHit = _service(<Object?>[
    <String, Object?>{'name': 'a', 'results': <Object?>[]},
  ]);
  final ToolResult emptyResult = await WebSearchTool(search: noHit).call(emptyCtx);

  // 全失败：文本追加未配置的源（来自 statuses）。
  final SearchService failing = _service(
    <Object?>[
      <String, Object?>{'name': 'a', 'fails': true, 'error': 'boom'},
    ],
    statuses: <Object?>[
      <String, Object?>{'name': 'a', 'available': true},
      <String, Object?>{'name': 'tavily', 'available': false, 'reason': '缺少 TAVILY_API_KEY'},
      <String, Object?>{'name': 'exa', 'available': false, 'reason': '缺少 EXA_API_KEY'},
    ],
  );
  final ToolResult failedResult = await WebSearchTool(search: failing).call(emptyCtx);

  // 未注册 provider 也会走到「无法联网」分支（经服务抛错）。
  final Map<String, Object?> searchTool = <String, Object?>{
    'hitText': hitResult.content,
    'hitValue': hitResult.value,
    'hitFailed': hitResult.isError,
    'emptyText': emptyResult.content,
    'emptyValue': emptyResult.value,
    'emptyFailed': emptyResult.isError,
    'failedText': failedResult.content,
    'failedError': failedResult.error?.code,
    'failedMessage': failedResult.error?.message,
  };

  // fetch_url：成功 / 非 http(s) / 抓取失败。
  // 注意：**抓取失败的用例必须真的失败**——第一版用同一个恒返回 200 的 client，
  // 于是「failing」其实成功了，期望值里落下的是正文（用例名不副实）。
  const String body = '<p>正文 &amp; 摘要</p>';
  const String failingURL = 'https://example.com/gone';
  final FetchUrlTool fetchTool = FetchUrlTool(
    fetcher: HttpFetcher(
      // 必须带 charset=utf-8：`http` 按 Content-Type 的 charset 解码 body，
      // 缺省走 latin1 会把中文正文解成乱码（fixture 会照着写下乱码期望值）。
      client: MockClient((http.Request request) async {
        const Map<String, String> headers = <String, String>{
          'content-type': 'text/html; charset=utf-8',
        };
        if (request.url.toString().startsWith(failingURL)) {
          return http.Response.bytes(utf8.encode(''), 404, headers: headers);
        }
        return http.Response.bytes(utf8.encode(body), 200, headers: headers);
      }),
    ),
    maxChars: 20000,
  );
  final ToolResult fetchOk = await fetchTool.call(
    const ToolContext(
      ToolCall(name: 'fetch_url', callId: 'c2', arguments: <String, Object?>{'url': 'https://example.com/p'}),
    ),
  );
  final ToolResult fetchBadScheme = await fetchTool.call(
    const ToolContext(
      ToolCall(name: 'fetch_url', callId: 'c3', arguments: <String, Object?>{'url': 'ftp://x/y'}),
    ),
  );
  final ToolResult fetchUnparseable = await fetchTool.call(
    const ToolContext(
      ToolCall(name: 'fetch_url', callId: 'c4', arguments: <String, Object?>{'url': '不是链接'}),
    ),
  );
  final ToolResult fetchFails = await fetchTool.call(
    const ToolContext(
      ToolCall(name: 'fetch_url', callId: 'c5', arguments: <String, Object?>{'url': failingURL}),
    ),
  );

  return <String, Object?>{
    'name': 'search-web-tools',
    'kind': 'search-web-tools',
    'cases': <Map<String, Object?>>[
      <String, Object?>{
        'scenario': 'web-search',
        'label': 'web_search：结果文本与结构化值、空结果、失败时列出未配置的源',
        'input': <String, Object?>{
          'query': 'swift',
          'limit': 2,
          'results': <Object?>[
            <String, Object?>{'title': '标题一', 'url': 'https://a.example/1', 'snippet': '摘要一'},
            <String, Object?>{'title': '标题二', 'url': 'https://a.example/2'},
          ],
          'statuses': <Object?>[
            <String, Object?>{'name': 'a', 'available': true},
            <String, Object?>{'name': 'tavily', 'available': false, 'reason': '缺少 TAVILY_API_KEY'},
            <String, Object?>{'name': 'exa', 'available': false, 'reason': '缺少 EXA_API_KEY'},
          ],
        },
        'expect': searchTool,
      },
      <String, Object?>{
        'scenario': 'fetch-url',
        'label': 'fetch_url：正文与 {url, format}、非 http(s) → INVALID_URL、抓取失败 → FETCH_FAILED',
        'input': <String, Object?>{
          'url': 'https://example.com/p',
          'maxChars': 20000,
          'response': <String, Object?>{'status': 200, 'body': '<p>正文 &amp; 摘要</p>'},
          'invalid': <String>['ftp://x/y', '不是链接'],
          'failing': <String, Object?>{
            'url': failingURL,
            'status': 404,
          },
        },
        'expect': <String, Object?>{
          'okText': fetchOk.content,
          'okValue': fetchOk.value,
          'okFailed': fetchOk.isError,
          'badSchemeText': fetchBadScheme.content,
          'badSchemeCode': fetchBadScheme.error?.code,
          'unparseableText': fetchUnparseable.content,
          'unparseableCode': fetchUnparseable.error?.code,
          'failedText': fetchFails.content,
          'failedCode': fetchFails.error?.code,
          'failedMessage': fetchFails.error?.message,
        },
      },
    ],
  };
}
