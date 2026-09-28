// S15 AWS SigV4 签名链 golden fixtures 导出器（fixtures 以 Dart 侧行为为准绳导出）。
//
// 用法与归一化总规则见 tool/export_fixtures/README.md。
// 时间一律显式传入（固定时刻），因此导出结果逐字节确定。
// 本文件只锁 conatus 的**可观察输出**（返回头表）；规范请求 / 待签串是私有实现，
// 其正确性由 S15 §8 的官方向量在 Swift 侧交叉校验。
import 'dart:convert';
import 'dart:io';

import 'package:conatus_credentials/conatus_credentials.dart';

const String _payload = '{"SecretId": "conatus/llm"}';
final Uri _endpoint = Uri.parse('https://secretsmanager.us-east-1.amazonaws.com/');
const Map<String, String> _businessHeaders = <String, String>{
  'Content-Type': 'application/x-amz-json-1.1',
  'X-Amz-Target': 'secretsmanager.GetSecretValue',
};

Future<void> main() async {
  final Directory outDir = _outputDir();
  outDir.createSync(recursive: true);
  final Map<String, Map<String, Object?>> fixtures = _fixtures();
  const JsonEncoder encoder = JsonEncoder.withIndent('  ');
  for (final MapEntry<String, Map<String, Object?>> entry in fixtures.entries) {
    File('${outDir.path}/${entry.key}.json')
        .writeAsStringSync('${encoder.convert(entry.value)}\n');
    stdout.writeln('导出 ${entry.key}.json');
  }
}

Directory _outputDir() {
  final Directory here = File.fromUri(Platform.script).parent;
  return Directory('${here.parent.parent.path}/spec/fixtures/s15');
}

Map<String, Map<String, Object?>> _fixtures() => <String, Map<String, Object?>>{
      'sign-basic': _signBasic(),
      'sign-normalization': _signNormalization(),
      'sign-edge': _signEdge(),
    };

/// 签名器（凭证与 region/service 与 Dart 测试同款，便于交叉比对）。
SigV4Signer _signer({String? sessionToken}) => SigV4Signer(
      accessKey: 'AKIDEXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      region: 'us-east-1',
      service: 'secretsmanager',
      sessionToken: sessionToken,
    );

/// 一次签名的完整头表（键排序，值逐字）。
Map<String, Object?> _headersOf(Map<String, String> headers) =>
    <String, Object?>{
      for (final String key in headers.keys.toList()..sort()) key: headers[key],
    };

Map<String, String> _sign({
  String method = 'POST',
  String uri = 'https://secretsmanager.us-east-1.amazonaws.com/',
  Map<String, String> headers = _businessHeaders,
  String payload = _payload,
  DateTime? timestamp,
  String? sessionToken,
  String region = 'us-east-1',
  String service = 'secretsmanager',
}) =>
    SigV4Signer(
      accessKey: 'AKIDEXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      region: region,
      service: service,
      sessionToken: sessionToken,
    ).sign(
      method: method,
      uri: Uri.parse(uri),
      headers: headers,
      payload: payload,
      timestamp: timestamp ?? DateTime.utc(2024),
    );

/// 解析 Authorization 头为三段（便于逐段断言而不依赖整串拼接细节）。
Map<String, Object?> _authorizationParts(String authorization) {
  final Match? match = RegExp(
    r'^AWS4-HMAC-SHA256 Credential=([^/]+)/([^,]+), SignedHeaders=([^,]+), Signature=(.+)$',
  ).firstMatch(authorization);
  if (match == null) {
    return <String, Object?>{'raw': authorization};
  }
  return <String, Object?>{
    'algorithm': 'AWS4-HMAC-SHA256',
    'accessKey': match.group(1),
    'scope': match.group(2),
    'signedHeaders': match.group(3)!.split(';'),
    'signature': match.group(4),
  };
}

/// kind = sign：一次签名 → 头表 + Authorization 三段 + SignedHeaders 列表。
Map<String, Object?> _case(
  String label, {
  String method = 'POST',
  String uri = 'https://secretsmanager.us-east-1.amazonaws.com/',
  Map<String, String> headers = _businessHeaders,
  String payload = _payload,
  String? timestamp,
  String? sessionToken,
  String region = 'us-east-1',
  String service = 'secretsmanager',
}) {
  final DateTime at = DateTime.parse(timestamp ?? '2024-01-01T00:00:00Z');
  final Map<String, String> signed = _sign(
    method: method,
    uri: uri,
    headers: headers,
    payload: payload,
    timestamp: at,
    sessionToken: sessionToken,
    region: region,
    service: service,
  );
  return <String, Object?>{
    'label': label,
    'request': <String, Object?>{
      'method': method,
      'uri': uri,
      'headers': headers,
      'payload': payload,
      'timestamp': DateTime.parse(timestamp ?? '2024-01-01T00:00:00Z')
          .toUtc()
          .toIso8601String(),
      if (sessionToken != null) 'sessionToken': sessionToken,
      if (region != 'us-east-1') 'region': region,
      if (service != 'secretsmanager') 'service': service,
    },
    'expect': <String, Object?>{
      'headers': _headersOf(signed),
      'authorization': _authorizationParts(signed['Authorization']!),
      'hostInSignedHeaders': (_authorizationParts(signed['Authorization']!)
              ['signedHeaders']! as List<Object?>)
          .contains('host'),
      'hasHostHeader': signed.containsKey('Host'),
    },
  };
}

// ───────────────────────────── 基础向量 ─────────────────────────────

Map<String, Object?> _signBasic() => <String, Object?>{
      'name': 'sign-basic',
      'kind': 'sign',
      'cases': <Map<String, Object?>>[
        _case('conatus 已知向量（Secrets Manager POST + 固定时刻）'),
        _case(
          '带会话令牌的临时凭证',
          sessionToken: 'SESSION-TOKEN',
        ),
        _case(
          '时区换算：+02:00 时刻折算为 UTC',
          timestamp: '2024-05-06T07:08:09+02:00',
        ),
        _case(
          '区域与服务进 scope',
          region: 'ap-northeast-1',
          service: 's3',
        ),
      ],
    };

// ───────────────────────────── 规范化边界 ─────────────────────────────

Map<String, Object?> _signNormalization() => <String, Object?>{
      'name': 'sign-normalization',
      'kind': 'sign',
      'cases': <Map<String, Object?>>[
        _case(
          '查询串按整串排序：键大小写敏感、同键多值按值排序',
          method: 'GET',
          uri: 'https://secretsmanager.us-east-1.amazonaws.com/?a=2&a=1&A=1&b=x%20y',
          payload: '',
        ),
        _case(
          '查询串解码 + 为空格、无值键取空串',
          method: 'GET',
          uri: 'https://secretsmanager.us-east-1.amazonaws.com/?flag&b=c+d&e==f',
          payload: '',
        ),
        _case(
          '路径段解码再编码：空格不二次编码、加号按字面量',
          method: 'GET',
          uri: 'https://secretsmanager.us-east-1.amazonaws.com/a%20b/c+d',
          payload: '',
        ),
        _case(
          '非 ASCII 路径段按 UTF-8 百分号编码',
          method: 'GET',
          uri: 'https://secretsmanager.us-east-1.amazonaws.com/%E4%B8%AD%E6%96%87',
          payload: '',
        ),
        _case(
          '空段保留：尾斜杠与连续斜杠',
          method: 'GET',
          uri: 'https://secretsmanager.us-east-1.amazonaws.com/a//b/',
          payload: '',
        ),
        _case(
          '无路径与根路径都规范为 /',
          method: 'GET',
          uri: 'https://secretsmanager.us-east-1.amazonaws.com',
          payload: '',
        ),
        _case(
          '头值去首尾空白参与签名',
          method: 'POST',
          headers: <String, String>{
            'Content-Type': '  application/x-amz-json-1.1  ',
            'X-Amz-Target': 'secretsmanager.GetSecretValue',
          },
        ),
        _case(
          '系统头覆盖同名业务头',
          method: 'POST',
          headers: <String, String>{
            'Content-Type': 'application/x-amz-json-1.1',
            'X-Amz-Date': '19990101T000000Z',
            'X-Amz-Target': 'secretsmanager.GetSecretValue',
          },
        ),
        _case(
          '方法原样参与签名（小写不规范化）',
          method: 'post',
        ),
      ],
    };

// ───────────────────────────── 载荷与确定性 ─────────────────────────────

/// 载荷哈希与字节级载荷：确定性（同输入同输出）由 Swift 侧单元测试断言
/// （fixture 只锁可观察头表，避免把「跑两次比一比」写进 fixture）。
Map<String, Object?> _signEdge() => <String, Object?>{
      'name': 'sign-edge',
      'kind': 'sign',
      'cases': <Map<String, Object?>>[
        _case(
          '空载荷的 content-sha256 是空串哈希',
          method: 'GET',
          payload: '',
        ),
        _case(
          '非 JSON 载荷照样按字节哈希',
          payload: 'not-json',
        ),
        _case(
          '载荷含换行与中文：按 UTF-8 字节哈希',
          payload: '{\n  "SecretId": "conatus/航班"\n}',
        ),
        _case(
          '长业务头参与签名',
          headers: <String, String>{
            'Content-Type': 'application/x-amz-json-1.1',
            'X-Amz-Target': 'secretsmanager.GetSecretValue',
            'X-Custom-Trace': 'trace-0123456789',
          },
        ),
      ],
    };
