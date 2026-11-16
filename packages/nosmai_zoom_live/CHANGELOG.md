## Unreleased

- iOS (15.0+): Zoom Video SDK 2.6.15 via CocoaPods. Nosmai's processed
  `CVPixelBuffer`s (BGRA or NV12) are scaled to Zoom's suggested size, sent as
  rotated landscape plus a rotation flag when portrait, and converted to I420
  (BT.601 limited) with Accelerate. Same channels, events, stats and errors as
  Android; the viewer renders through Zoom's `UIView`. Not yet tested on a device.
- `NosmaiZoomLive.initialize` uses `iosLicenseKey` on iOS.

## 1.0.0

- First release as a Flutter plugin (Android). Host apps contain no native
  bridge code and need only `minSdk 28`.
- `NosmaiZoomLive.initialize` registers the shared GL context before Nosmai
  starts, then initializes Nosmai.
- `NosmaiLiveBroadcaster` and `NosmaiLiveViewer` / `NosmaiLiveViewerView` run
  the Zoom Video SDK session flow (join, publish, leave) with states, stats and
  typed errors, in the same shape as `nosmai_tencent_live`.
- Tokens are checked before joining (`tpc`, `role_type`, `exp`, `app_key`) so
  mismatches get a clear message instead of a generic Zoom error.
- Portrait video reaches viewers whole and upright: frames are sent as rotated
  landscape plus a rotation flag (Zoom centre-crops portrait input).
- The viewer renders through Zoom's TextureView, composed as a normal Flutter
  texture (no hybrid composition, no ghost overlays), and Zoom initializes before
  the view exists (it crashed when a permission dialog appeared first).
- Zoom's slow first initialize runs inside `NosmaiZoomLive.initialize`, not on
  the first `start()`.
- Android: GPU RGBA→I420 conversion of Nosmai's shared texture with an
  automatic fallback to Nosmai's I420 frames; even frame pacing; thermal FPS cap.
- The plugin brings the Zoom Video SDK (2.6.15), its permissions and its R8
  keep rules.
- `NosmaiLiveStats.nosmaiFps`: the preview's frame rate, next to `sendFps`.
- `NosmaiLiveVideoConfig.prioritizeFrameRate` (default on): Zoom keeps the
  configured frame rate and lowers the resolution instead (Zoom out rose from ~24
  to 28–30 fps for a 30 fps feed). Zoom's suggested 25 fps is no longer a cap,
  and pacing tolerates camera jitter, so send fps matches the preview.
