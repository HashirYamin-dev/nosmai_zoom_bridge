import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:nosmai_zoom_live/src/native_bridge.dart';

final testNow = DateTime.utc(2026, 11, 11, 12);

String jwt({String session = 'stream', int role = 1, DateTime? expires}) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final exp = (expires ?? testNow.add(const Duration(hours: 2))).millisecondsSinceEpoch ~/ 1000;
  final claims = {'app_key': 'key', 'tpc': session, 'role_type': role, 'version': 1, 'exp': exp};
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part(claims)}.signature';
}

/// Records calls and plays the native side: `joined` after join, `left` after leave.
class FakeBridge extends NativeBridge {
  FakeBridge({this.camera = true, this.microphone = true, this.autoJoin = true, this.joinError});

  final controller = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final calls = <String>[];
  bool camera;
  bool microphone;
  bool autoJoin;
  PlatformException? joinError;
  Map<String, Object?>? joinArguments;
  Map<Object?, Object?>? statsSample;

  void emit(Map<String, Object?> event) => controller.add(event);

  @override
  Stream<Map<String, Object?>> get events => controller.stream;

  @override
  Future<bool> prepare() async {
    calls.add('prepare');
    return true;
  }

  @override
  Future<({bool camera, bool microphone})> requestPermissions({bool camera = true}) async {
    calls.add('permissions');
    return (camera: this.camera, microphone: microphone);
  }

  @override
  Future<void> join(Map<String, Object?> arguments) async {
    calls.add('join');
    joinArguments = arguments;
    final error = joinError;
    if (error != null) throw error;
    if (autoJoin) scheduleMicrotask(() => emit({'type': 'joined'}));
  }

  @override
  Future<void> leave({required bool endSession}) async {
    calls.add('leave:$endSession');
    scheduleMicrotask(() => emit({'type': 'left', 'reason': 'BySelf'}));
  }

  @override
  Future<void> setMicMuted(bool muted) async => calls.add('mic:$muted');

  @override
  Future<void> setVideoMuted(bool muted) async => calls.add('video:$muted');

  @override
  Future<void> setSpeakerMuted(bool muted) async => calls.add('speaker:$muted');

  @override
  Future<void> setForeground(bool foreground) async => calls.add('foreground:$foreground');

  @override
  Future<void> setMaxFps(int fps) async => calls.add('fps:$fps');

  @override
  Future<Map<Object?, Object?>?> stats() async => statsSample;
}
