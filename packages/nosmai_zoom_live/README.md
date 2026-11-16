# nosmai_zoom_live

Livestream the Nosmai camera through the **Zoom Video SDK** from Flutter, with
Nosmai's beauty, makeup, AR effects, backgrounds, colour filters and cloud
filters applied. **You write only Dart.** The plugin contains all the Android
code and brings the Zoom Video SDK with it.

```
NosmaiCameraPreview (Nosmai owns the camera, applies effects)
        │ processed frames
        ▼
nosmai_zoom_live (native, inside the plugin)
        │ Zoom external video source
        ▼
Zoom Video SDK session  ──►  NosmaiLiveViewerView on other phones
```

Viewers need neither Nosmai nor a Nosmai license. The effects are already in
the video they receive.

> This is the Zoom counterpart of `nosmai_tencent_live`. The API is the same
> shape (`initialize`, `NosmaiLiveBroadcaster`, `NosmaiLiveViewer`,
> `NosmaiLiveViewerView`, states, stats and error codes); only the
> credentials differ.

## Requirements

| | |
|---|---|
| Flutter | 3.29 or later |
| Android | **minSdk 28** (a Zoom Video SDK requirement), physical arm64 phone, OpenGL ES 3 |
| iOS | **15.0** or later, physical iPhone (no simulator: Nosmai's iOS SDK has no arm64 simulator slice). Code complete; device test pending |
| Nosmai | A license key per platform: Android bound to your applicationId, iOS to your bundle identifier |
| Zoom | A Video SDK app (Zoom App Marketplace → Develop → Build Video SDK), plus a session JWT per user issued by your server |

The plugin depends on `nosmai_effects_sdk` 2.0.x and on the Zoom Video SDK
`us.zoom.videosdk:zoomvideosdk-core` 2.6.15 (Maven Central) on Android and the
`ZoomVideoSDK/ZoomVideoSDK` 2.6.15 CocoaPod on iOS, and pulls them in for you.

## Install

```yaml
dependencies:
  nosmai_zoom_live:
    path: packages/nosmai_zoom_live   # or a git: dependency on this repository
```

### Platform setup

**Android:** raise `minSdk` in `android/app/build.gradle(.kts)`:

```kotlin
defaultConfig {
    minSdk = 28
}
```

That is the only change. The plugin merges the camera, microphone, Bluetooth
and network permissions, and the R8 keep rules for Zoom and Nosmai. You do not
need to edit `MainActivity`, the manifest, ProGuard files or Gradle repositories.

**iOS:** set the platform in `ios/Podfile` and add the two usage descriptions to
`ios/Runner/Info.plist`:

```ruby
platform :ios, '15.0'
```

```xml
<key>NSCameraUsageDescription</key>
<string>Camera is used for the live video with Nosmai effects.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone is used for live audio.</string>
```

Pass the iOS key as well: `NosmaiZoomLive.initialize(androidLicenseKey: ..., iosLicenseKey: ...)`.
On iOS Nosmai's processed `CVPixelBuffer`s are scaled, turned to landscape when
portrait, converted to I420 with Accelerate and sent to Zoom; the viewer renders
through Zoom's own `UIView` (a `UiKitView`).

## Quick start

### 1. Initialize once

```dart
import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

await NosmaiZoomLive.requestPermissions();          // camera + microphone
await NosmaiZoomLive.initialize(androidLicenseKey: 'YOUR_NOSMAI_ANDROID_KEY');
```

Call `NosmaiZoomLive.initialize` **instead of** `NosmaiFlutter.initialize`. It
must run first: it connects Nosmai to the stream's GPU context before Nosmai
starts. If Nosmai was already initialized, streaming still works, but frames go
through a slower CPU copy.

### 2. Show the camera and apply effects

The whole Nosmai API is re-exported. `NosmaiZoomLive.effects` is
`NosmaiFlutter.instance`.

```dart
// In your widget tree. Mount exactly one preview.
const NosmaiCameraPreview()

// Anywhere, before or during the broadcast:
final nosmai = NosmaiZoomLive.effects;
await nosmai.applySkinSmoothing(0.5);
final items = await nosmai.getCloudFilters(page: 1, limit: 30);
final download = await nosmai.downloadCloudFilter(items.first.cloudIdentifier);
await nosmai.applyEffect(download['path'] as String);
```

Viewers see whatever the preview shows, including changes made while live.

### 3. Go live

```dart
final live = NosmaiLiveBroadcaster(
  credentials: NosmaiLiveCredentials(
    token: hostTokenFromYourServer,     // Video SDK JWT, role_type 1, tpc = session name
    userName: 'Host',
  ),
  session: const NosmaiLiveSession('my-stream'),   // optional: password: '...'
  video: NosmaiLiveVideoConfig.hd,                 // low | standard (default) | hd
);

try {
  await live.start();    // completes when the session is joined
} on NosmaiLiveException catch (e) {
  showError(e.message);
}

live.setMicMuted(true);
live.setVideoMuted(true);
await live.switchCamera();
await live.stop();       // ends the session for viewers (endSessionOnStop: true)
live.dispose();
```

`NosmaiLiveBroadcaster` is a `ChangeNotifier`. Rebuild your UI from
`live.state`, `live.stats`, `live.error` and `live.warning`.

### 4. Watch

```dart
final viewer = NosmaiLiveViewer(
  credentials: NosmaiLiveCredentials(token: viewerToken, userName: 'Viewer 7'), // role_type 0
  session: const NosmaiLiveSession('my-stream'),
  // hostUserName: 'Host',   // optional; otherwise the session host sending video
);
await viewer.start();

// In build():
NosmaiLiveViewerView(
  viewer: viewer,
  placeholder: const Center(child: Text('Waiting for host…')),
)

await viewer.stop();
viewer.dispose();
```

When the broadcaster stops with `endSessionOnStop: true`, the viewer moves to
`stopped` and `viewer.endedByHost` is true.

## API summary

| Member | Purpose |
|---|---|
| `NosmaiZoomLive.initialize({androidLicenseKey})` | Starts Nosmai with the shared GPU context |
| `NosmaiZoomLive.requestPermissions()` | Camera and microphone prompt; returns `NosmaiLivePermissions` |
| `NosmaiZoomLive.effects` | `NosmaiFlutter.instance`, Nosmai's full effects API |
| `NosmaiZoomLive.zoomSdkVersion()` | The bundled Zoom Video SDK version |
| `NosmaiLiveBroadcaster` | `start`, `stop`, `setMicMuted`, `setVideoMuted`, `switchCamera`, `setMaxFps` |
| `NosmaiLiveViewer` / `NosmaiLiveViewerView` | `start`, `stop`, `setSpeakerMuted`, `hasVideo`, `watchingUserName`, `endedByHost` |
| `NosmaiLiveSession` | Session name (the token's `tpc`) and optional password |
| `NosmaiLiveCredentials` | Session JWT and display name |
| `NosmaiZoomToken` | Decodes a token's claims and explains mismatches before joining |
| `NosmaiLiveVideoConfig` | `resolution` (360p–1080p), `fps` (≤30), `adaptToThermalState`, `prioritizeFrameRate` |
| `NosmaiLiveState` | `idle`, `connecting`, `waitingForHost`, `live`, `reconnecting`, `paused`, `stopping`, `stopped`, `failed` |
| `NosmaiLiveStats` | Zoom's size, fps, latency, loss and network quality, plus `nosmaiFps` (preview rate), `sendFps` (rate handed to Zoom), Nosmai→Zoom frame counters, `transport`, CPU and memory |

### Video presets

| Preset | Resolution | FPS |
|---|---|---|
| `NosmaiLiveVideoConfig.low` | 360×640 | 15 |
| `NosmaiLiveVideoConfig.standard` | 540×960 | 24 |
| `NosmaiLiveVideoConfig.hd` | 720×1280 | 30 |

With `prioritizeFrameRate` (on by default), the plugin asks Zoom to keep the
configured frame rate and lower the resolution instead when bandwidth or the
encoder runs short. With Zoom's default balance, a 30 fps feed left Zoom at about
24 fps. With this option it sent 28–30.

For the smoothest stream, prefer 540p at 30 FPS
(`NosmaiLiveVideoConfig(resolution: NosmaiLiveResolution.p540, fps: 30)`).
Measured on a Pixel 5 host: at 720p, Zoom's encoder took enough of the phone
that the Nosmai preview dropped to 16–24 fps. At 540p, preview, send and Zoom
output all held 29–30 fps. A heavy effect (background replacement) can still
lower the preview rate. That rate is Nosmai's own rendering, measured the same
with and without Zoom encoding, and the stream carries every frame the preview
renders.

Zoom chooses the bitrate and may send less on a weak network. It sends
1080p only if 1080p is enabled for your Zoom account. With
`adaptToThermalState` (on by default), the frame rate is capped at 15 FPS
while the phone reports *severe* heat and at 10 FPS at *critical*.

### Error codes (`NosmaiLiveException.code`)

| Code | Meaning |
|---|---|
| `missing_license_key` | No Nosmai key was passed |
| `license_rejected` | Nosmai refused the key (wrong applicationId) |
| `unsupported_platform` | Not Android |
| `not_initialized` | `NosmaiZoomLive.initialize` was not called before `start` |
| `invalid_config` | Bad session name or password |
| `invalid_token` | The JWT is malformed, expired, for another session, or has the wrong `role_type` |
| `permission_denied` | Camera or microphone denied (broadcast with `publishAudio: false` to skip audio) |
| `already_active` | Another broadcaster or viewer is still in a session. Zoom allows one per app |
| `start_failed` | Zoom refused or timed out. The message says why |
| `stopped` | `stop()` was called while starting |

## Tokens

Zoom Video SDK tokens are HS256 JWTs signed with your **SDK secret**. Sign them
on your server, never in the app. Claims:

| Claim | Value |
|---|---|
| `app_key` | Your Video SDK key |
| `tpc` | The session name; must equal `NosmaiLiveSession.name` |
| `role_type` | `1` for the broadcaster, `0` for viewers |
| `version`, `iat`, `exp` | `1`, issue time, expiry (at most 48 h after `iat`) |

Zoom's [videosdk-auth-endpoint-sample](https://github.com/zoom/videosdk-auth-endpoint-sample)
is a ready-made server. The example app's `tools/zoom_token.py` signs
development tokens and can serve the same contract on your LAN.

## Lifecycle behaviour

- Nosmai owns the camera. Zoom gets an external video source and never opens one.
- Frames are produced only while Zoom asks for them (`onStartSend` →
  `onStopSend`), so an idle app does no conversion work.
- By default, backgrounding the app pauses video and microphone (broadcaster)
  or audio and video (viewer), and returning resumes them (`handleAppLifecycle`).
- Network drops reconnect automatically (`reconnecting` state).
- The screen stays awake while a session is active (`keepScreenOn`).
- `stop()` halts frames, leaves the session and waits for Zoom to confirm. It is
  safe to call repeatedly and from `dispose`.

## How it works (Android)

At `initialize`, the plugin creates a small OpenGL ES 3 context and registers it
with Nosmai as the share context, so Nosmai's renderer joins that share group.
While live, each processed Nosmai texture goes through Nosmai's consumer
protocol (`waitStreamFrame` → GPU work → `completeStreamFrame`). One shader pass
converts RGBA to I420 (BT.601 limited range), scales to the configured size and
turns the portrait image into a landscape frame (Zoom centre-crops portrait input
to 16:9, so portrait travels as landscape plus a rotation flag, the way camera
sensor frames do),
then one `glReadPixels` copies the result into a pooled direct buffer for
`ZoomVideoSDKVideoSender.sendVideoFrame`. This runs on a dedicated GL thread,
so Nosmai's render thread never waits.

If sharing is unavailable (Nosmai initialized first, or the driver refuses), the
plugin falls back to Nosmai's I420 frame callback. `stats.transport` reports
`texture` or `i420`. Frames are paced evenly to the configured FPS, because
encoders expect a steady cadence.

## Validation status

- Unit tests cover start/stop ordering, token and config validation, failure
  handling, reconnect and background states, and the viewer's host binding
  (`flutter test`, 21 tests).
- A stock `flutter create` app that only adds this plugin and sets `minSdk 28`
  builds for Android, in debug and in release with R8.
- Two-phone test with real Zoom credentials: OnePlus CPH2515 (Android 14) as the
  broadcaster, Samsung Galaxy A52s (Android 14) as the viewer. The viewer gets the
  full portrait picture, upright and unmirrored, with filters (an on-screen text
  effect reads correctly), on both the GPU texture path and the CPU `i420`
  fallback. Ending the broadcast moves the viewer to `stopped` with
  `endedByHost`. Stop/Start repeats without restarting the app. The thermal cap
  engaged at the phone's *severe* state (15 FPS).
- Still to do before release: long sessions, weak networks, and more phone models.

## Troubleshooting

| Symptom | Check |
|---|---|
| `Manifest merger failed … minSdkVersion 24 cannot be smaller than version 28` | Set `minSdk = 28` in the app (see Platform setup) |
| `invalid_token` | Read the message: it names the claim that does not match |
| Viewer stays on `waitingForHost` | Same session name for both, broadcaster `state == live`, valid tokens from the same Zoom app |
| `license_rejected` / watermark | The Nosmai key was issued for this applicationId |
| `stats.transport == 'i420'` | `NosmaiFlutter.initialize` ran before `NosmaiZoomLive.initialize` |
| `framesFromNosmai` stays 0 | The `NosmaiCameraPreview` must be on screen while live |
| Viewer gets a cropped landscape strip | Fixed in 1.0.0: portrait frames go out rotated with a rotation flag, because Zoom centre-crops portrait input |
| Ghost text over the viewer's video | Fixed in 1.0.0: the viewer uses Zoom's TextureView renderer instead of hybrid composition |
| Viewer stays on `waitingForHost` after a crash | A force-stopped participant lingers in the Zoom session for a while; the broadcaster's `stop()` (with `endSessionOnStop`) clears it |
