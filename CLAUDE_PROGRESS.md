# CLAUDE_PROGRESS — nosmai_zoom_bridge

Goal (from the senior): a Zoom Video SDK package built like the Tencent one (`nosmai_tencent_live` in
../nosmai_tencent_livestreaming/packages). Android first, then iOS.

## Done
- [x] Android app prototype: Nosmai → Zoom external video source (GPU texture→I420 with I420 fallback).
- [x] 2026-11-11: Restructured into plugin `packages/nosmai_zoom_live` (Kotlin, same API shape as nosmai_tencent_live);
      the root app is now its example app with no native code.
- [x] Plugin: 21 Dart tests; analyze clean. Example: 3 tests; analyze clean.
- [x] Builds: example debug + release R8; stock `flutter create` app + plugin (minSdk 28) debug + release R8.
- [x] OnePlus CPH2515: Nosmai init via plugin, license valid, preview + cloud filters, token error path.

- [x] 2026-11-11: Zoom credentials in config/zoom_secrets.json (git-ignored). Host LIVE on OnePlus: path texture,
      25 fps (Zoom suggests 1280x720@25), ~10 ms conversion, Stop/Start repeat OK. Zoom init moved to prepare
      (it blocked the main thread ~1.5 s on first Start Live).

- [x] 2026-11-11: Two-phone test (OnePlus host, Samsung A52s viewer): upright full portrait on texture and i420 paths.
      Fixes: rotate portrait→landscape + ROTATION_ACTION_270 (90 was upside down); i420 rows are bottom-up;
      Zoom init before creating its view (crash); TextureView renderer (ghost overlays); Zoom init in prepare.
      Example build uses --build-number=3 to install over older com.nosmai.effect builds.

## Remaining
- [ ] Long-session, weak-network and multi-device tests; viewer audio check by ear.
- [ ] iOS implementation of the plugin.
- [ ] Decide hosting (own git repo like nosmai_tencent_live, or this repo + git path dependency).

## Resume
Flutter: `~/fvm/default/bin/flutter`. Old app-level code backup (pre-plugin) was kept only in the session scratchpad.
