/// Portrait sizes for the broadcast, by their long side.
///
/// Zoom sends at most 720p unless 1080p is enabled for your Zoom account; it
/// may also send less on a weak network.
enum NosmaiLiveResolution {
  p360(640),
  p540(960),
  p720(1280),
  p1080(1920);

  const NosmaiLiveResolution(this.longSide);

  /// Height of a portrait frame, in pixels.
  final int longSide;
}

/// How the broadcaster sends Nosmai's processed video to Zoom.
///
/// Nosmai renders at 720x1280; frames are scaled down to [resolution] on the
/// GPU before Zoom encodes them. Zoom picks the bitrate itself.
class NosmaiLiveVideoConfig {
  const NosmaiLiveVideoConfig({
    this.resolution = NosmaiLiveResolution.p540,
    this.fps = 24,
    this.adaptToThermalState = true,
    this.prioritizeFrameRate = true,
  }) : assert(fps >= 1 && fps <= 30, 'fps must be between 1 and 30');

  /// 360p at 15 FPS: weak networks and older phones.
  static const low = NosmaiLiveVideoConfig(resolution: NosmaiLiveResolution.p360, fps: 15);

  /// 540p at 24 FPS: the default balance of quality, heat and bandwidth.
  static const standard = NosmaiLiveVideoConfig();

  /// 720p at 30 FPS.
  static const hd = NosmaiLiveVideoConfig(resolution: NosmaiLiveResolution.p720, fps: 30);

  final NosmaiLiveResolution resolution;
  final int fps;

  /// Lowers the frame rate while the phone reports severe (15 FPS) or
  /// critical (10 FPS) heat, so a long broadcast does not overheat it.
  final bool adaptToThermalState;

  /// Asks Zoom to keep [fps] and lower the resolution when bandwidth or the
  /// encoder runs short. When false, Zoom balances both and usually sends
  /// fewer frames than it receives.
  final bool prioritizeFrameRate;
}
