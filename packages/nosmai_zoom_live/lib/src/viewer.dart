import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'credentials.dart';
import 'native_bridge.dart';
import 'stats.dart';
import 'zoom_session.dart';

/// Watches a broadcaster in a Zoom Video SDK session. Viewers do not need
/// Nosmai or a Nosmai license: effects are already part of the received video.
///
/// ```dart
/// final viewer = NosmaiLiveViewer(
///   credentials: NosmaiLiveCredentials(token: viewerToken, userName: 'Viewer 7'),
///   session: const NosmaiLiveSession('my-stream'),
/// );
/// await viewer.start();
/// // build: NosmaiLiveViewerView(viewer: viewer)
/// ```
class NosmaiLiveViewer extends ChangeNotifier with WidgetsBindingObserver {
  NosmaiLiveViewer({
    required this.credentials,
    required this.session,
    this.hostUserName,
    this.handleAppLifecycle = true,
    this.keepScreenOn = true,
    @visibleForTesting NativeBridge bridge = const NativeBridge(),
    @visibleForTesting Duration statsInterval = const Duration(seconds: 1),
    @visibleForTesting Duration joinTimeout = const Duration(seconds: 25),
    @visibleForTesting DateTime Function()? clock,
  })  : _bridge = bridge,
        _statsInterval = statsInterval,
        _joinTimeout = joinTimeout,
        _clock = clock ?? DateTime.now;

  final NosmaiLiveCredentials credentials;
  final NosmaiLiveSession session;

  /// The broadcaster to watch, by user name. When null: the session host
  /// sending video, else anyone sending video.
  final String? hostUserName;

  /// Pause playback in the background and resume in the foreground.
  final bool handleAppLifecycle;

  /// Keep the screen awake while watching.
  final bool keepScreenOn;

  final NativeBridge _bridge;
  final Duration _statsInterval;
  final Duration _joinTimeout;
  final DateTime Function() _clock;

  ZoomLiveSession? _session;
  Future<void>? _stopFuture;
  NosmaiLiveState _state = NosmaiLiveState.idle;
  String? _error;
  bool _speakerMuted = false;
  bool _disposed = false;

  NosmaiLiveState get state => _state;
  NosmaiLiveStats get stats => _session?.stats ?? NosmaiLiveStats.empty;
  String? get error => _error;
  String? get warning => _session?.warning;
  bool get speakerMuted => _speakerMuted;

  /// True while the broadcaster's video is on screen.
  bool get hasVideo => _session?.remoteVideo ?? false;

  /// The broadcaster being watched, once one is found.
  String? get watchingUserName => _session?.remoteUserName;

  /// True when the session ended because the broadcaster stopped it.
  bool get endedByHost => _session?.endedByHost ?? false;

  /// Joins the session. Completes once joined; video follows when the
  /// broadcaster is live. Throws [NosmaiLiveException] on failure.
  Future<void> start() async {
    if (_state != NosmaiLiveState.idle) {
      throw StateError('A viewer can be started once; create a new one.');
    }
    _setState(NosmaiLiveState.connecting);
    try {
      final configProblem = session.validate();
      if (configProblem != null) throw NosmaiLiveException('invalid_config', configProblem);
      final tokenProblem = credentials.validate(session: session, broadcaster: false, now: _clock());
      if (tokenProblem != null) throw NosmaiLiveException('invalid_token', tokenProblem);
      // Zoom's audio connects through the microphone permission even for
      // listeners; without it video still plays.
      await _bridge.requestPermissions(camera: false);
      _throwIfStopped();

      final zoom = ZoomLiveSession(
        bridge: _bridge,
        isHost: false,
        statsInterval: _statsInterval,
        joinTimeout: _joinTimeout,
        joinArguments: {
          'host': false,
          'sessionName': session.name,
          'password': session.password,
          'token': credentials.token,
          'userName': credentials.userName,
          'speakerMuted': _speakerMuted,
          'hostUserName': hostUserName,
          'keepScreenOn': keepScreenOn,
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

  void setSpeakerMuted(bool muted) {
    _speakerMuted = muted;
    _session?.setSpeakerMuted(muted);
    _notify();
  }

  void _throwIfStopped() {
    if (_stopFuture != null || _disposed) {
      throw const NosmaiLiveException('stopped', 'The viewer was stopped while starting.');
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
    if (zoom.endedByHost) {
      unawaited(_stopFuture ??= _shutdown());
      return;
    }
    final NosmaiLiveState next;
    if (!zoom.joined) {
      next = NosmaiLiveState.connecting;
    } else if (!zoom.foreground) {
      next = NosmaiLiveState.paused;
    } else if (zoom.reconnecting) {
      next = NosmaiLiveState.reconnecting;
    } else if (zoom.remoteVideo) {
      next = NosmaiLiveState.live;
    } else {
      next = NosmaiLiveState.waitingForHost;
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

/// Renders the video a [NosmaiLiveViewer] receives, through Zoom's own renderer.
///
/// Shows [placeholder] until the broadcaster's video is on screen.
class NosmaiLiveViewerView extends StatelessWidget {
  const NosmaiLiveViewerView({super.key, required this.viewer, this.placeholder});

  final NosmaiLiveViewer viewer;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final supported = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    return Stack(fit: StackFit.expand, children: [
      if (supported) const _ZoomVideoView(),
      ListenableBuilder(
        listenable: viewer,
        builder: (context, _) =>
            viewer.hasVideo ? const SizedBox.shrink() : (placeholder ?? const SizedBox.shrink()),
      ),
    ]);
  }
}

/// Android: Zoom renders into a TextureView, which Flutter composes as a texture layer.
/// iOS: Zoom renders into a UIView embedded as a UiKitView.
class _ZoomVideoView extends StatelessWidget {
  const _ZoomVideoView();

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(
        viewType: NativeBridge.remoteVideoViewType,
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    return const AndroidView(
      viewType: NativeBridge.remoteVideoViewType,
      creationParamsCodec: StandardMessageCodec(),
    );
  }
}
