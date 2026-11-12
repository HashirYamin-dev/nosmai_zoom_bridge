import 'dart:convert';

/// A Zoom Video SDK session, identified by name (the token's `tpc` claim).
///
/// Everyone who uses the same [name] (with tokens from the same Zoom app)
/// meets in the same session. Zoom creates the session on the first join.
class NosmaiLiveSession {
  const NosmaiLiveSession(this.name, {this.password = ''});

  /// Up to 200 characters. Must equal the `tpc` claim of every token.
  final String name;

  /// Optional session password, up to 10 characters. Everyone must use the same one.
  final String password;

  /// A human-readable problem, or null when the values are usable.
  String? validate() {
    if (name.trim().isEmpty) return 'The session name is empty.';
    if (name.length > 200) return 'The session name must be at most 200 characters.';
    if (password.length > 10) return 'The session password must be at most 10 characters.';
    return null;
  }

  @override
  String toString() => 'session "$name"';

  @override
  bool operator ==(Object other) =>
      other is NosmaiLiveSession && other.name == name && other.password == password;

  @override
  int get hashCode => Object.hash(name, password);
}

/// Zoom Video SDK identity for one participant.
///
/// [token] is a Video SDK JWT signed with your SDK secret **on your server**.
/// Never ship the SDK secret inside a mobile app. The broadcaster needs a
/// token with `role_type` 1 (host); viewers need `role_type` 0.
class NosmaiLiveCredentials {
  const NosmaiLiveCredentials({required this.token, required this.userName});

  final String token;

  /// The name other participants see.
  final String userName;

  /// A human-readable problem, or null when the token fits this join.
  String? validate({required NosmaiLiveSession session, required bool broadcaster, DateTime? now}) {
    if (userName.trim().isEmpty) return 'userName is empty.';
    return NosmaiZoomToken.problemFor(token,
        sessionName: session.name, broadcaster: broadcaster, now: now);
  }

  @override
  String toString() => 'NosmaiLiveCredentials(userName: $userName)';
}

/// The claims of a Zoom Video SDK JWT, decoded without checking the signature
/// (only Zoom can). Used to catch mismatches before joining, when Zoom's own
/// errors are vaguer.
class NosmaiZoomToken {
  const NosmaiZoomToken({this.sessionName, this.roleType, this.expiresAt, this.appKey});

  /// `tpc`: the only session this token can join.
  final String? sessionName;

  /// `role_type`: 1 for host, 0 for participant.
  final int? roleType;

  /// `exp`.
  final DateTime? expiresAt;

  /// `app_key`: the Video SDK key that signed the token.
  final String? appKey;

  /// Decodes [token], or returns null when it is not a JWT.
  static NosmaiZoomToken? tryParse(String token) {
    final parts = token.trim().split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      if (payload is! Map) return null;
      final exp = payload['exp'];
      return NosmaiZoomToken(
        sessionName: payload['tpc']?.toString(),
        roleType: (payload['role_type'] as num?)?.toInt(),
        expiresAt: exp is num ? DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true) : null,
        appKey: payload['app_key']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// A human-readable problem with [token] for this join, or null.
  static String? problemFor(String token,
      {required String sessionName, required bool broadcaster, DateTime? now}) {
    final role = broadcaster ? 'broadcaster' : 'viewer';
    if (token.trim().isEmpty) return 'The $role token is empty. Issue one from your server.';
    final info = tryParse(token);
    if (info == null) return 'The $role token is not a JWT.';
    if (info.appKey == null || info.appKey!.isEmpty) {
      return 'The $role token has no app_key claim; it is not a Zoom Video SDK token.';
    }
    if (info.sessionName != sessionName) {
      return 'The $role token is for session "${info.sessionName}", not "$sessionName".';
    }
    final expectedRole = broadcaster ? 1 : 0;
    if (info.roleType != expectedRole) {
      return 'The $role token has role_type ${info.roleType}; a $role needs $expectedRole.';
    }
    final exp = info.expiresAt;
    if (exp != null && !exp.isAfter(now ?? DateTime.now())) {
      return 'The $role token expired at ${exp.toLocal()}. Issue a new one.';
    }
    return null;
  }
}
