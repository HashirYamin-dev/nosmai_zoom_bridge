import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nosmai_effects_sdk/nosmai_effects_sdk.dart';

import 'native_bridge.dart';
import 'stats.dart';

/// Camera and microphone permission state.
class NosmaiLivePermissions {
  const NosmaiLivePermissions({required this.camera, required this.microphone});

  final bool camera;
  final bool microphone;

  bool get allGranted => camera && microphone;
}

/// Entry point: initializes Nosmai for livestreaming through Zoom.
///
/// ```dart
/// await NosmaiZoomLive.initialize(androidLicenseKey: 'NOSMAI_ANDROID_KEY');
/// ```
///
/// After this, every Nosmai feature is available through
/// [NosmaiZoomLive.effects] (the same object as `NosmaiFlutter.instance`).
class NosmaiZoomLive {
  NosmaiZoomLive._();

  static NativeBridge _bridge = const NativeBridge();
  static Future<void>? _initializing;
  static bool _initialized = false;

  /// Nosmai's effects API: beauty, makeup, filters, AR effects, backgrounds,
  /// cloud filters, camera switching and capture.
  static NosmaiFlutter get effects => NosmaiFlutter.instance;

  /// Whether [initialize] has completed successfully.
  static bool get isInitialized => _initialized;

  /// Initializes Nosmai with the license key for the current platform.
  ///
  /// Call once, before showing `NosmaiCameraPreview`. Do not call
  /// `NosmaiFlutter.initialize` yourself: on Android this method must run
  /// first so Nosmai shares GPU textures with the stream (otherwise frames
  /// fall back to a slower CPU copy).
  ///
  /// Nosmai keys are bound to the app: Android to the applicationId, iOS to
  /// the bundle identifier. Throws [NosmaiLiveException] if the key is missing
  /// or rejected.
  static Future<void> initialize({String? androidLicenseKey, String? iosLicenseKey}) {
    if (_initialized) return Future.value();
    return _initializing ??=
        _initialize(androidLicenseKey, iosLicenseKey).whenComplete(() => _initializing = null);
  }

  static Future<void> _initialize(String? androidKey, String? iosKey) async {
    final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    if (kIsWeb || (defaultTargetPlatform != TargetPlatform.android && !ios)) {
      throw const NosmaiLiveException(
          'unsupported_platform', 'nosmai_zoom_live runs on Android and iOS devices only.');
    }
    final key = (ios ? iosKey : androidKey)?.trim() ?? '';
    if (key.isEmpty) {
      throw NosmaiLiveException(
          'missing_license_key', 'Pass the Nosmai ${ios ? 'iOS' : 'Android'} license key.');
    }
    // iOS frames reach Zoom as CVPixelBuffers, so the order does not matter there.
    if (!ios && NosmaiFlutter.instance.isInitialized) {
      debugPrint('[NosmaiZoomLive] Nosmai was initialized before NosmaiZoomLive.initialize; '
          'frames will reach Zoom through the slower CPU path.');
    }
    // Must precede NosmaiFlutter.initialize (see the method documentation).
    await _bridge.prepare();
    final accepted = NosmaiFlutter.instance.isInitialized || await NosmaiFlutter.initialize(key);
    if (!accepted) {
      throw const NosmaiLiveException('license_rejected',
          'Nosmai rejected the license key. Check that it was issued for this '
          'platform and this applicationId (Android) or bundle identifier (iOS).');
    }
    _initialized = true;
  }

  /// Asks for camera and microphone access if not already decided.
  static Future<NosmaiLivePermissions> requestPermissions() async {
    final result = await _bridge.requestPermissions();
    return NosmaiLivePermissions(camera: result.camera, microphone: result.microphone);
  }

  /// The bundled Zoom Video SDK version, for logs and support requests.
  static Future<String> zoomSdkVersion() => _bridge.zoomVersion();

  @visibleForTesting
  static set bridgeForTesting(NativeBridge bridge) => _bridge = bridge;

  @visibleForTesting
  static void resetForTesting() {
    _bridge = const NativeBridge();
    _initializing = null;
    _initialized = false;
  }
}
