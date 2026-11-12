import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_bridge.dart';
import 'stats.dart';

/// One Zoom Video SDK session for a broadcaster or a viewer.
///
/// Zoom runs natively; its outcomes arrive as events from the plugin, and this
/// class turns them into flags the broadcaster and viewer map to states.
class ZoomLiveSession extends ChangeNotifier {
  ZoomLiveSession({
    required this.bridge,
    required this.isHost,
    required this.joinArguments,
    this.endSessionOnClose = false,
    this.joinTimeout = const Duration(seconds: 25),
    this.leaveTimeout = const Duration(seconds: 5),
    this.firstFrameTimeout = const Duration(seconds: 15),
    this.statsInterval = const Duration(seconds: 1),
  });

  final NativeBridge bridge;
  final bool isHost;
  final Map<String, Object?> joinArguments;

  /// Broadcaster: end the session for everyone on close.
  final bool endSessionOnClose;
  final Duration joinTimeout;
  final Duration leaveTimeout;
  final Duration firstFrameTimeout;
  final Duration statsInterval;

  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _joinTimer;
  Timer? _frameTimer;
  Timer? _statsTimer;
  Completer<void>? _leftSignal;
  Future<void>? _closeFuture;
  bool _nativeActive = false;
  bool _started = false;
  bool _disposed = false;
  bool _foreground = true;

  bool joined = false;
  bool reconnecting = false;
  bool closing = false;
  bool closed = false;

  /// Broadcaster: Zoom is asking for frames.
  bool sending = false;

  /// Viewer: the watched broadcaster's video is on screen.
  bool remoteVideo = false;

  /// Viewer: the broadcaster being watched.
  String? remoteUserName;

  /// Viewer: the broadcaster ended the session.
  bool endedByHost = false;

  String? error;
  String? warning;
  NosmaiLiveStats stats = NosmaiLiveStats.empty;

  bool get foreground => _foreground;

  /// Completes when the session is joined, or with an error if it fails first.
  Future<void> get entered => _entered.future;
  final Completer<void> _entered = Completer<void>();

  Future<void> start() async {
    if (_started || closing || _disposed) return;
    _started = true;
    _events = bridge.events.listen(_onEvent);
    _joinTimer = Timer(joinTimeout, () {
      _fail('Joining the Zoom session timed out. Check the network and that the token '
          'was signed with your Video SDK credentials.');
    });
    try {
      await bridge.join(joinArguments);
      if (closing) return;
      _nativeActive = true;
    } on PlatformException catch (e) {
      _fail(e.message ?? e.code, code: e.code);
    } catch (e) {
      _fail('Could not start Zoom: $e');
    }
  }

  void _onEvent(Map<String, Object?> event) {
    if (_disposed || closed) return;
    switch (event['type']) {
      case 'joined':
        if (closing) return;
        _joinTimer?.cancel();
        joined = true;
        reconnecting = false;
        if (!_entered.isCompleted) _entered.complete();
        _statsTimer ??= Timer.periodic(statsInterval, (_) => unawaited(_refreshStats()));
        if (isHost) _watchFirstFrame();
      case 'left':
        _nativeActive = false;
        joined = false;
        sending = false;
        remoteVideo = false;
        final signal = _leftSignal;
        if (signal != null && !signal.isCompleted) signal.complete();
        if (closing) break;
        final reason = event['reason']?.toString() ?? 'Unknown';
        if (!isHost && reason == 'EndByHost') {
          endedByHost = true;
          unawaited(close());
        } else {
          _fail(switch (reason) {
            'EndByHost' => 'The Zoom session was ended.',
            'KickByHost' => 'Removed from the Zoom session by its host.',
            'NetworkError' => 'Disconnected from Zoom by a network error.',
            _ => 'The Zoom session ended ($reason).',
          });
        }
      case 'reconnecting':
        if (closing) return;
        reconnecting = true;
      case 'error':
        if (event['fatal'] == true) {
          _fail(event['message']?.toString() ?? 'Zoom error ${event['code']}.');
          return;
        }
        warning = event['message']?.toString();
      case 'warning':
        warning = event['message']?.toString();
      case 'remoteVideo':
        remoteUserName = event['userName']?.toString();
        remoteVideo = event['on'] == true;
        if (remoteVideo) warning = null;
      case 'sending':
        sending = event['on'] == true;
      default:
        return;
    }
    _notify();
  }

  Future<void> _refreshStats() async {
    if (closing || _disposed) return;
    try {
      final next = NosmaiLiveStats.fromNative(await bridge.stats());
      if (closing || _disposed) return;
      stats = next;
      // Zoom reports reconnecting but not recovery; media flowing again is recovery.
      final flowing = isHost ? next.framesSent > 0 && next.sendFps > 0 : next.fps > 0;
      if (reconnecting && flowing) reconnecting = false;
      if (isHost && next.framesSent > 0) _frameTimer?.cancel();
      _notify();
    } catch (_) {/* Stats must never break the session. */}
  }

  void _watchFirstFrame() {
    _frameTimer?.cancel();
    _frameTimer = Timer(firstFrameTimeout, () {
      if (closing || !_foreground || stats.framesSent > 0) return;
      warning = 'No video sent yet. Keep the Nosmai camera preview on screen.';
      _notify();
    });
  }

  void setMicMuted(bool muted) => _send(() => bridge.setMicMuted(muted));

  void setVideoMuted(bool muted) => _send(() => bridge.setVideoMuted(muted));

  void setSpeakerMuted(bool muted) => _send(() => bridge.setSpeakerMuted(muted));

  void setForeground(bool foreground) {
    if (closing || _foreground == foreground) return;
    _foreground = foreground;
    _send(() => bridge.setForeground(foreground));
    _notify();
  }

  void _send(Future<void> Function() call) {
    if (closing || _disposed) return;
    unawaited(call().catchError((Object e) {
      warning = e is PlatformException ? (e.message ?? e.code) : '$e';
      _notify();
    }));
  }

  void _fail(String message, {String? code}) {
    if (closing || _disposed) return;
    error = message;
    failureCode = code;
    if (!_entered.isCompleted) _entered.completeError(StateError(message));
    _notify();
    unawaited(close());
  }

  /// The plugin's error code for [error], when it came from native code.
  String? failureCode;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closing = true;
    _joinTimer?.cancel();
    _frameTimer?.cancel();
    _statsTimer?.cancel();
    if (!_entered.isCompleted) {
      _entered.completeError(StateError(error ?? 'The session was closed.'));
    }
    // Callers that never awaited [entered] must not see an unhandled error.
    unawaited(_entered.future.catchError((_) {}));
    _notify();
    if (_nativeActive || (_started && !joined && error == null)) {
      final signal = _leftSignal = Completer<void>();
      try {
        await bridge.leave(endSession: endSessionOnClose);
        if (_nativeActive) await signal.future.timeout(leaveTimeout);
      } catch (_) {
        warning = 'Zoom did not confirm leaving the session.';
      }
    }
    await _events?.cancel();
    _events = null;
    _nativeActive = false;
    joined = false;
    sending = false;
    remoteVideo = false;
    closed = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    _disposed = true;
    super.dispose();
  }
}
