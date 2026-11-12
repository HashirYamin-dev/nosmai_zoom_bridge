import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zoom_bridge/src/config.dart';

String jwt(Map<String, Object?> claims) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.sig';
}

void main() {
  // resolveToken checks against the real clock.
  final future = DateTime.utc(2100).millisecondsSinceEpoch ~/ 1000;
  final host = jwt({'app_key': 'k', 'tpc': 'room', 'role_type': 1, 'version': 1, 'exp': future});
  final viewer = jwt({'app_key': 'k', 'tpc': 'room', 'role_type': 0, 'version': 1, 'exp': future});

  test('resolveToken prefers the pasted token and validates it', () async {
    const config = AppConfig(hostToken: 'ignored');
    final token = await resolveToken(config: config, host: true, sessionName: 'room', userName: 'u', pasted: host);
    expect(token, host);
    expect(() => resolveToken(config: config, host: false, sessionName: 'room', userName: 'u', pasted: host),
        throwsA(isA<TokenException>()));
  });

  test('resolveToken falls back to the build-time token for the role', () async {
    const config = AppConfig();
    final withTokens = AppConfig(hostToken: host, viewerToken: viewer);
    expect(await resolveToken(config: withTokens, host: false, sessionName: 'room', userName: 'u'), viewer);
    expect(() => resolveToken(config: config, host: true, sessionName: 'room', userName: 'u'),
        throwsA(isA<TokenException>().having((e) => e.message, 'message', contains('empty'))));
  });
}
