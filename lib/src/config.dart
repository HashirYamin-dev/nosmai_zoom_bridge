import 'dart:convert';
import 'dart:io';

import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

/// Build-time configuration of this example (`--dart-define-from-file=config/local.json`).
///
/// Only short-lived session tokens or a token-server URL reach the app.
/// The Zoom SDK secret never does: tokens are signed by tools/zoom_token.py
/// or your own backend.
class AppConfig {
  const AppConfig({
    this.nosmaiLicenseKey = '',
    this.nosmaiIosLicenseKey = '',
    this.sessionName = '',
    this.sessionPassword = '',
    this.hostToken = '',
    this.viewerToken = '',
    this.tokenUrl = '',
  });

  const AppConfig.fromEnvironment()
      : nosmaiLicenseKey = const String.fromEnvironment('NOSMAI_LICENSE_KEY'),
        nosmaiIosLicenseKey = const String.fromEnvironment('NOSMAI_IOS_LICENSE_KEY'),
        sessionName = const String.fromEnvironment('ZOOM_SESSION_NAME', defaultValue: 'nosmai-live'),
        sessionPassword = const String.fromEnvironment('ZOOM_SESSION_PASSWORD'),
        hostToken = const String.fromEnvironment('ZOOM_HOST_TOKEN'),
        viewerToken = const String.fromEnvironment('ZOOM_VIEWER_TOKEN'),
        tokenUrl = const String.fromEnvironment('ZOOM_TOKEN_URL');

  /// Nosmai key for Android (bound to the applicationId).
  final String nosmaiLicenseKey;

  /// Nosmai key for iOS (bound to the bundle identifier). Empty: [nosmaiLicenseKey] is used.
  final String nosmaiIosLicenseKey;

  String get iosLicenseKey => nosmaiIosLicenseKey.isNotEmpty ? nosmaiIosLicenseKey : nosmaiLicenseKey;
  final String sessionName;
  final String sessionPassword;
  final String hostToken;
  final String viewerToken;

  /// Optional token endpoint using the contract of Zoom's
  /// videosdk-auth-endpoint-sample: POST {sessionName, role, userIdentity,
  /// expirationSeconds} -> `{"signature": "<jwt>"}`.
  final String tokenUrl;

  String tokenFor({required bool host}) => host ? hostToken : viewerToken;
}

/// Picks the token for a join: pasted > token server > build-time define.
Future<String> resolveToken({
  required AppConfig config,
  required bool host,
  required String sessionName,
  required String userName,
  String pasted = '',
}) async {
  String token;
  if (pasted.trim().isNotEmpty) {
    token = pasted.trim();
  } else if (config.tokenUrl.isNotEmpty) {
    token = await _fetchToken(config.tokenUrl, host: host, sessionName: sessionName, userName: userName);
  } else {
    token = config.tokenFor(host: host);
  }
  final problem = NosmaiZoomToken.problemFor(token, sessionName: sessionName, broadcaster: host);
  if (problem != null) throw TokenException(problem);
  return token;
}

Future<String> _fetchToken(String url, {required bool host, required String sessionName, required String userName}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'sessionName': sessionName,
      'role': host ? 1 : 0,
      'userIdentity': userName,
      'expirationSeconds': 7200,
    }));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw TokenException('Token server returned HTTP ${response.statusCode}.');
    }
    final data = jsonDecode(body);
    final token = data is Map ? (data['signature'] ?? data['token'])?.toString() : null;
    if (token == null || token.isEmpty) throw const TokenException('Token server response has no "signature".');
    return token;
  } on TokenException {
    rethrow;
  } catch (e) {
    throw TokenException('Token server unreachable: $e');
  } finally {
    client.close(force: true);
  }
}

class TokenException implements Exception {
  const TokenException(this.message);
  final String message;
  @override
  String toString() => message;
}
