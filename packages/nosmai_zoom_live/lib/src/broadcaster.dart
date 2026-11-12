import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

import 'credentials.dart';
import 'native_bridge.dart';
import 'stats.dart';
import 'video_config.dart';
import 'zoom_session.dart';

/// Publishes the Nosmai camera, with every applied effect, to a Zoom Video SDK session.
///
/// Show a `NosmaiCameraPreview` on the same screen; Nosmai owns the camera
/// and whatever the preview shows is what viewers receive.
///
/// ```dart
/// final live = NosmaiLiveBroadcaster(
///   credentials: NosmaiLiveCredentials(token: hostToken, userName: 'Host'),
///   session: const NosmaiLiveSession('my-stream'),
/// );
/// await live.start();
/// // ... apply effects with NosmaiZoomLive.effects ...
/// await live.stop();
/// ```
class NosmaiLiveBroadcaster extends ChangeNotifier with WidgetsBindingObserver {
  NosmaiLiveBroadcaster({
    required this.credentials,
    required this.session,
    this.video = NosmaiLiveVideoConfig.standard,
    this.publishAudio = true,
    this.endSessionOnStop = true,
    this.handleAppLifecycle = true,
    this.keepScreenOn = true,
    @visibleForTesting NativeBridge bridge = const NativeBridge(),
    @visibleForTesting Duration statsInterval = const Duration(seconds: 1),
    @visibleForTesting Duration joinTimeout = const Duration(seconds: 25),
    @visibleForTesting bool Function()? nosmaiReady,
    @visibleForTesting DateTime Function()? clock,
  })  : _bridge = bridge,
        _statsInterval = statsInterval,
        _joinTimeout = joinTimeout,
        _nosmaiReady = nosmaiReady ?? (() => NosmaiFlutter.instance.isInitialized),
        _clock = clock ?? DateTime.now;

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveSession session;
  final NosmaiLiveVideoConfig video;

  /// Publish the microphone along with the video.
  final bool publishAudio;

  /// End the Zoom session for every viewer when [stop] is called. When false,
  /// viewers stay in the session and wait for a broadcaster.
  final bool endSessionOnStop;

  /// Pause publishing in the background and resume in the foreground.
  final bool handleAppLifecycle;

  /// Keep the screen awake while live.
  final bool keepScreenOn;

  final NativeBridge _bridge;
  final Duration _statsInterval;
  final Duration _joinTimeout;
  final bool Function() _nosmaiReady;
  final DateTime Function() _clock;

  ZoomLiveSession? _session;
  Future<void>? _stopFuture;
  NosmaiLiveState _state = NosmaiLiveState.idle;
  String? _error;
  bool _micMuted = false;
  bool _videoMuted = false;
  bool _disposed = false;

  NosmaiLiveState get state => _state;
  NosmaiLiveStats get stats => _session?.stats ?? NosmaiLiveStats.empty;

  /// Why the broadcast failed, when [state] is [NosmaiLiveState.failed].
  String? get error => _error;

  /// A non-fatal problem worth showing, such as a slow first frame.
  String? get warning {
    final session = _session;
    if (session == null) return null;
    if (session.warning != null) return session.warning;
    final note = session.stats.pipelineNote;
    return note.isEmpty ? null : note;
  }

  bool get isLive => _state == NosmaiLiveState.live;
  bool get micMuted => _micMuted || !publishAudio;
  bool get videoMuted => _videoMuted;

  /// Joins the session and starts publishing. Completes once the session is
  /// joined; throws [NosmaiLiveException] on failure.
  Future<void> start() async {
    if (_state != NosmaiLiveState.idle) {
      throw StateError('A broadcaster can be started once; create a new one.');
    }
    _setState(NosmaiLiveState.connecting);
    try {
      final configProblem = session.validate();
      if (configProblem != null) throw NosmaiLiveException('invalid_config', configProblem);
      final tokenProblem = credentials.validate(session: session, broadcaster: true, now: _clock());
      if (tokenProblem != null) throw NosmaiLiveException('invalid_token', tokenProblem);
      if (!_nosmaiReady()) {
        throw const NosmaiLiveException('not_initialized',
            'Call NosmaiZoomLive.initialize before starting a broadcast.');
      }
      final permissions = await _bridge.requestPermissions();
      if (!permissions.camera) {
        throw const NosmaiLiveException('permission_denied', 'Camera access is required to broadcast.');
      }
      if (publishAudio && !permissions.microphone) {
        throw const NosmaiLiveException('permission_denied',
            'Microphone access is required to broadcast with audio. '
            'Pass publishAudio: false to broadcast video only.');
      }
      _throwIfStopped();

      final zoom = ZoomLiveSession(
        bridge: _bridge,
        isHost: true,
        endSessionOnClose: endSessionOnStop,
        statsInterval: _statsInterval,
        joinTimeout: _joinTimeout,
        joinArguments: {
          'host': true,
          'sessionName': session.name,
          'password': session.password,
          'token': credentials.token,
          'userName': credentials.userName,
          'micMuted': micMuted,
          'videoMuted': _videoMuted,
          'keepScreenOn': keepScreenOn,
          'fps': video.fps,
          'maxLongSide': video.resolution.longSide,
          'adaptToThermalState': video.adaptToThermalState,
          'prioritizeFrameRate': video.prioritizeFrameRate,
        },
      );
      _session = zoom;
      zoom.addListener(_onSessionChanged);
      if (handleAppLifecycle) WidgetsBinding.instance.addObserver(this);
      await zoom.start();
      await zoom.entered;
      _throwIfStopped();
      _onSessionChanged();
    } catch (e) {
      final failure = _session?.error;
      final code = switch (e) {
        NosmaiLiveException(:final code) => code,
        _ => _session?.failureCode ?? 'start_failed',
      };
      final message = switch (e) {
        NosmaiLiveException(:final message) => message,
        StateError(:final message) => failure ?? message,
        _ => failure ?? '$e',
      };
      await (_stopFuture ??= _shutdown(failure: message));
      throw NosmaiLiveException(code, message);
    }
  }

  /// Leaves the session. Safe to call at any time and more than once.
  Future<void> stop() => _stopFuture ??= _shutdown();

  void setMicMuted(bool muted) {
    if (!publishAudio) return;
    _micMuted = muted;
    _session?.setMicMuted(muted);
    _notify();
  }

  /// Stops sending video while muted; audio and the session stay.
  void setVideoMuted(bool muted) {
    _videoMuted = muted;
    _session?.setVideoMuted(muted);
    _notify();
  }

  /// Switches between front and back cameras. The stream continues.
  Future<void> switchCamera() => NosmaiFlutter.instance.switchCamera();

  /// Changes the published frame rate (1-30) without restarting.
  Future<void> setMaxFps(int fps) => _bridge.setMaxFps(fps.clamp(1, 30));

  void _throwIfStopped() {
    if (_stopFuture != null || _disposed) {
      throw const NosmaiLiveException('stopped', 'The broadcast was stopped while starting.');
    }
    final failure = _session?.error;
    if (failure != null) {
      throw NosmaiLiveException(_session?.failureCode ?? 'start_failed', failure);
    }
  }

  void _onSessionChanged() {
    final zoom = _session;
    if (zoom == null || _stopFuture != null) return;
    if (zoom.error != null) {
      _error = zoom.error;
      unawaited(_stopFuture ??= _shutdown(failure: zoom.error));
      return;
    }
    final NosmaiLiveState next;
    if (!zoom.joined) {
      next = NosmaiLiveState.connecting;
    } else if (!zoom.foreground) {
      next = NosmaiLiveState.paused;
    } else if (zoom.reconnecting) {
      next = NosmaiLiveState.reconnecting;
    } else if (zoom.sending || _videoMuted) {
      next = NosmaiLiveState.live;
    } else {
      next = NosmaiLiveState.connecting;
    }
    _setState(next);
  }

  Future<void> _shutdown({String? failure}) async {
    if (failure != null) _error = failure;
    if (_state != NosmaiLiveState.idle) _setState(NosmaiLiveState.stopping);
    if (handleAppLifecycle) WidgetsBinding.instance.removeObserver(this);
    final zoom = _session;
    if (zoom != null) {
      zoom.removeListener(_onSessionChanged);
      try {
        await zoom.close();
      } catch (_) {/* Best effort. */}
      _error ??= zoom.error;
      zoom.dispose();
    }
    _setState(_error != null ? NosmaiLiveState.failed : NosmaiLiveState.stopped);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final zoom = _session;
    if (zoom == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        zoom.setForeground(true);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        zoom.setForeground(false);
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _setState(NosmaiLiveState next) {
    _state = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
