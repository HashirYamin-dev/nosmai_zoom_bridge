import 'package:flutter/services.dart';

/// Thin wrapper over the plugin's channels; replaceable in tests.
class NativeBridge {
  const NativeBridge();

  static const _methods = MethodChannel('nosmai_zoom_live');
  static const _eventChannel = EventChannel('nosmai_zoom_live/events');

  /// Platform view type of the viewer's video.
  static const remoteVideoViewType = 'nosmai_zoom_live/remote_video';

  // One shared subscription: every listener sees the same native event stream,
  // and the platform side is only told to stop when nobody listens.
  static final Stream<Map<String, Object?>> _events = _eventChannel
      .receiveBroadcastStream()
      .map((raw) => raw is Map ? Map<String, Object?>.from(raw) : const <String, Object?>{});

  /// Session events: `joined`, `left {reason}`, `reconnecting`,
  /// `error {code, message, fatal}`, `warning {message}`,
  /// `remoteVideo {userName, on}` and `sending {on}`.
  Stream<Map<String, Object?>> get events => _events;

  /// Android: registers the shared GL context Nosmai must join. Call before
  /// Nosmai initializes. Returns whether a share context exists.
  Future<bool> prepare() async {
    final result = await _methods.invokeMapMethod<Object?, Object?>('prepare');
    return result?['sharedContext'] == true;
  }

  Future<({bool camera, bool microphone})> requestPermissions({bool camera = true}) async {
    final result =
        await _methods.invokeMapMethod<Object?, Object?>('requestPermissions', {'camera': camera});
    return (camera: result?['camera'] == true, microphone: result?['microphone'] == true);
  }

  /// Starts joining. Completes when Zoom accepted the request; `joined` follows.
  Future<void> join(Map<String, Object?> arguments) =>
      _methods.invokeMapMethod<Object?, Object?>('join', arguments);

  /// Leaves the session; `left` follows if a session was active.
  Future<void> leave({required bool endSession}) =>
      _methods.invokeMethod<void>('leave', {'endSession': endSession});

  Future<void> setMicMuted(bool muted) => _methods.invokeMethod<void>('setMicMuted', {'muted': muted});

  Future<void> setVideoMuted(bool muted) => _methods.invokeMethod<void>('setVideoMuted', {'muted': muted});

  Future<void> setSpeakerMuted(bool muted) =>
      _methods.invokeMethod<void>('setSpeakerMuted', {'muted': muted});

  Future<void> setForeground(bool foreground) =>
      _methods.invokeMethod<void>('setForeground', {'foreground': foreground});

  Future<void> setMaxFps(int fps) => _methods.invokeMethod<void>('setMaxFps', {'fps': fps});

  Future<Map<Object?, Object?>?> stats() => _methods.invokeMapMethod<Object?, Object?>('stats');

  Future<String> zoomVersion() async {
    final result = await _methods.invokeMapMethod<Object?, Object?>('version');
    return result?['zoom']?.toString() ?? '';
  }
}
