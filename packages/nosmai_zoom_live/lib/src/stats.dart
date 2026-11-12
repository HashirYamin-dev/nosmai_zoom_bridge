/// Where a broadcaster or viewer is in its lifecycle.
enum NosmaiLiveState {
  /// Created, `start` not called yet.
  idle,

  /// Joining the Zoom session.
  connecting,

  /// Viewer only: in the session, no broadcaster video yet.
  waitingForHost,

  /// Broadcaster: video is being sent. Viewer: the broadcaster's video is playing.
  live,

  /// The network dropped; Zoom is reconnecting automatically.
  reconnecting,

  /// Paused because the app is in the background.
  paused,

  /// Leaving the session.
  stopping,

  /// Left the session normally (or, for a viewer, the broadcaster ended it).
  stopped,

  /// Stopped because of an error; see `error`.
  failed;

  bool get isActive =>
      this == connecting ||
      this == waitingForHost ||
      this == live ||
      this == reconnecting ||
      this == paused;
}

/// Live quality numbers, refreshed about once per second while active.
/// Every value is measured, either by Zoom or by the plugin's frame pipeline.
class NosmaiLiveStats {
  const NosmaiLiveStats({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitrateKbps = 0,
    this.latencyMs = 0,
    this.rttMs = 0,
    this.lossPercent = 0,
    this.network = '',
    this.participants = 0,
    this.framesFromNosmai = 0,
    this.framesSent = 0,
    this.framesDropped = 0,
    this.nosmaiFps = 0,
    this.sendFps = 0,
    this.convertMs = 0,
    this.transport = '',
    this.pipelineNote = '',
    this.cpuPercent = 0,
    this.memoryMb = 0,
  });

  static const empty = NosmaiLiveStats();

  /// Parses the plugin's native stats sample.
  factory NosmaiLiveStats.fromNative(Map<Object?, Object?>? raw) {
    Map<Object?, Object?> part(String key) {
      final value = raw?[key];
      return value is Map ? value : const {};
    }

    final zoom = part('zoom');
    final source = part('source');
    final process = part('process');
    int i(Map<Object?, Object?> m, String k) => (m[k] as num?)?.round() ?? 0;
    double d(Map<Object?, Object?> m, String k) => (m[k] as num?)?.toDouble() ?? 0;
    return NosmaiLiveStats(
      width: i(zoom, 'width'),
      height: i(zoom, 'height'),
      fps: i(zoom, 'fps'),
      bitrateKbps: i(zoom, 'bitrateKbps'),
      latencyMs: i(zoom, 'latencyMs'),
      rttMs: i(zoom, 'rttMs'),
      lossPercent: d(zoom, 'lossPercent'),
      network: zoom['network']?.toString() ?? '',
      participants: i(zoom, 'participants'),
      framesFromNosmai: i(source, 'framesIn'),
      framesSent: i(source, 'sent'),
      framesDropped: i(source, 'dropped'),
      nosmaiFps: d(source, 'inputFps'),
      sendFps: d(source, 'txFps'),
      convertMs: d(source, 'convertMsAvg'),
      transport: source['transport']?.toString() ?? '',
      pipelineNote: source['lastError']?.toString() ?? '',
      cpuPercent: d(process, 'cpuPercent'),
      memoryMb: d(process, 'rssMb'),
    );
  }

  /// Zoom's sent (broadcaster) or received (viewer) video size.
  final int width;
  final int height;

  /// Zoom's sent (broadcaster) or received (viewer) frame rate.
  final int fps;

  /// Viewer only: received video bitrate.
  final int bitrateKbps;

  /// Zoom's send (broadcaster) or receive (viewer) latency.
  final int latencyMs;

  /// Viewer only: round trip to Zoom for the watched video.
  final int rttMs;

  /// Average packet loss in the sending (broadcaster) or receiving (viewer) direction.
  final double lossPercent;

  /// Zoom's network quality: `Good`, `Normal`, `Bad` or `Unknown`.
  final String network;

  /// Other people in the session.
  final int participants;

  /// Broadcaster only: processed frames Nosmai delivered.
  final int framesFromNosmai;

  /// Broadcaster only: frames handed to Zoom.
  final int framesSent;

  /// Broadcaster only: frames skipped because the pipeline was busy.
  final int framesDropped;

  /// Broadcaster only: frames per second Nosmai rendered, which is the preview's
  /// frame rate. Measured while live.
  final double nosmaiFps;

  /// Broadcaster only: frames per second handed to Zoom, measured by the plugin.
  /// Lower than [nosmaiFps] when pacing to Zoom's rate or the thermal cap.
  final double sendFps;

  /// Broadcaster only: average time to turn a Nosmai frame into Zoom's I420 buffer.
  final double convertMs;

  /// Broadcaster only: `texture` (GPU conversion) or `i420` (Nosmai CPU frames).
  final String transport;

  /// Broadcaster only: why the pipeline fell back or dropped frames, if it did.
  final String pipelineNote;

  /// This app's CPU use, as a percent of one core.
  final double cpuPercent;

  /// This app's resident memory.
  final double memoryMb;

  @override
  String toString() => '${width}x$height@${fps}fps ${bitrateKbps}kbps latency=${latencyMs}ms '
      'loss=${lossPercent.toStringAsFixed(1)}% nosmai=$framesFromNosmai sent=$framesSent '
      'dropped=$framesDropped $transport';
}

/// Thrown for configuration and setup problems the app can fix.
class NosmaiLiveException implements Exception {
  const NosmaiLiveException(this.code, this.message);

  /// Stable identifier, e.g. `invalid_token` or `permission_denied`.
  final String code;
  final String message;

  @override
  String toString() => 'NosmaiLiveException($code): $message';
}
