# Nosmai × Zoom Video SDK Live

Two things live in this repository:

- **[`packages/nosmai_zoom_live`](packages/nosmai_zoom_live)**: a Flutter plugin that livestreams the
  Nosmai-filtered camera through the **Zoom Video SDK** (not the Meeting SDK). Apps using it write only Dart.
  It is the Zoom counterpart of `nosmai_tencent_live` and has the same API shape. **Start with its README.**
- **This app** (repository root): the example app for the plugin. It has a host screen (preview, filters,
  Start/Stop Live, mic, camera switch, live stats) and a viewer screen. It contains no native code.

```
Camera ─► Nosmai (filters/AR, GPU) ─► processed GL texture
   ─► GPU RGBA→I420 (shared GL context, dedicated thread) ─► ZoomVideoSDKVideoSender ─► viewers
Fallback: Nosmai I420 frame callback ─► one copy ─► sendVideoFrame
```

| | Version |
|---|---|
| Zoom Video SDK (Android) | `us.zoom.videosdk:zoomvideosdk-core:2.6.15`, brought in by the plugin |
| Nosmai | `nosmai_effects_sdk 2.0.2` → `nosmai-sdk 3.0.7` |
| Flutter | 3.29+ (built with 3.47.5). Android minSdk 28, OpenGL ES 3. iOS 15+ (code complete, device test pending) |

## Run the example

1. **Zoom credentials** (Zoom App Marketplace → Develop → Build Video SDK → *SDK credentials*):
   ```bash
   cp config/zoom_secrets.example.json config/zoom_secrets.json   # paste SDK Key + Secret
   python3 tools/zoom_token.py --session nosmai-live               # writes config/local.json
   ```
   This writes a host token (`role_type 1`) and a viewer token (`role_type 0`) into `config/local.json`.
   Both are valid for 2 hours. The SDK secret never goes into the app. Rerun the command when the tokens expire.
   Tokens are compiled into the build, so run the app again after regenerating them.
2. **Nosmai key**: set `NOSMAI_LICENSE_KEY` in `config/local.json`. The key is bound to applicationId
   `com.nosmai.effect`, so this app can't be installed next to the Tencent example, which uses the same id.
   On iOS the app's bundle id is `com.vativeApps.NosmaiAR`; put the Nosmai key issued for it in `NOSMAI_IOS_LICENSE_KEY`.
3. **Run** on two arm64 phones:
   ```bash
   flutter run --dart-define-from-file=config/local.json
   ```
   On phone A choose **Host**, then **Start Live**. On phone B choose **Viewer** with the same session name.

**Token server (optional)**: run `python3 tools/zoom_token.py --serve --port 4000` and set
`"ZOOM_TOKEN_URL": "http://<mac-lan-ip>:4000"`. Plain HTTP is allowed in debug builds only. The endpoint follows the
contract of Zoom's `videosdk-auth-endpoint-sample` (`POST {sessionName, role}` → `{signature}`). A JWT pasted on the
home screen overrides both.

**Filters**: `.nosmai` files placed in `assets/filters/` appear as local filters. The Nosmai cloud catalog is listed
after them, and cloud filters download when tapped.

**Release APK**: `flutter build apk --release --split-per-abi --target-platform android-arm64 --dart-define-from-file=config/local.json`
→ `app-arm64-v8a-release.apk` (~172 MB, almost all of it Zoom and Nosmai native libraries; Play delivers per ABI from an AAB).

## Code map

| Path | Role |
|---|---|
| `packages/nosmai_zoom_live/lib/` | Public Dart API: `NosmaiZoomLive`, `NosmaiLiveBroadcaster`, `NosmaiLiveViewer(View)`, config, stats, token checks |
| `packages/nosmai_zoom_live/android/.../NosmaiZoomLivePlugin.kt` | Channels, permissions, keep-screen-on, remote video platform view |
| `packages/nosmai_zoom_live/android/.../ZoomSession.kt` | Zoom init/join/leave, mute, background pause, reconnect, viewer subscription, stats |
| `packages/nosmai_zoom_live/android/.../NosmaiZoomVideoSource.kt` | Zoom external video source fed by Nosmai: pacing, thermal cap, texture→I420 with I420 fallback |
| `packages/nosmai_zoom_live/android/.../I420Converter.kt`, `SharedGlContext.kt` | One-pass GPU RGBA→I420; the ES3 share context registered with Nosmai before it initializes |
| `lib/` | Example app: home, host and viewer screens, stats overlay, token resolution |
| `tools/zoom_token.py` | Signs development JWTs off-device; `--serve` dev token endpoint |

## Verification status

- Plugin: `flutter analyze` is clean and `flutter test` passes 21 tests. Example: `flutter analyze` is clean and
  `flutter test` passes 3 tests. `python3 tools/test_zoom_token.py` passes.
- Builds: the example builds as a debug APK and as a release arm64 APK with R8. A fresh `flutter create` app that only
  adds the plugin and sets `minSdk 28` builds in debug and in release.
- Two-phone test with real Zoom credentials (OnePlus CPH2515 host, Samsung Galaxy A52s viewer, both Android 14): the
  viewer gets the full portrait picture, upright and unmirrored, with Nosmai filters. This holds on the GPU texture
  path and on the CPU `i420` fallback. Stop/Start repeats without restarting the app, the viewer reports the end of
  the live, and the thermal cap engages (15 fps at *severe*).
- Fixed during that test: portrait frames were centre-cropped by Zoom (now sent as rotated landscape plus a rotation
  flag), the viewer crashed if a permission dialog appeared before Zoom initialized, ghost text appeared over the
  viewer's video (now a TextureView), and the first Start Live froze the UI for ~1.5 s (Zoom now initializes earlier).

- iOS: the plugin's native iOS code (`packages/nosmai_zoom_live/ios/Classes`) builds in a debug iOS build with no
  warnings. It has not been run on an iPhone yet. Run it from Xcode (`ios/Runner.xcworkspace`) after
  `flutter build ios --debug --no-codesign --dart-define-from-file=config/local.json`, which writes the dart-defines
  Xcode uses. Set `NOSMAI_IOS_LICENSE_KEY` in `config/local.json` if the iOS key differs from the Android one.

**Still to do before release:** iOS device test (orientation, colours, viewer), long sessions, weak networks and more
phone models.
