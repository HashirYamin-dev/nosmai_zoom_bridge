import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NosmaiLiveBroadcaster broadcaster(FakeBridge bridge,
          {String? token, bool ready = true, bool publishAudio = true, bool endSessionOnStop = true}) =>
      NosmaiLiveBroadcaster(
        credentials: NosmaiLiveCredentials(token: token ?? jwt(), userName: 'Host'),
        session: const NosmaiLiveSession('stream'),
        video: NosmaiLiveVideoConfig.hd,
        publishAudio: publishAudio,
        endSessionOnStop: endSessionOnStop,
        bridge: bridge,
        nosmaiReady: () => ready,
        clock: () => testNow,
        statsInterval: const Duration(days: 1),
      );

  test('joins, goes live once Zoom asks for frames, and ends the session on stop', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    final states = <NosmaiLiveState>[];
    live.addListener(() => states.add(live.state));

    await live.start();
    expect(live.state, NosmaiLiveState.connecting);
    expect(bridge.joinArguments, containsPair('host', true));
    expect(bridge.joinArguments, containsPair('maxLongSide', 1280));
    expect(bridge.joinArguments, containsPair('fps', 30));
    expect(bridge.joinArguments, containsPair('micMuted', false));
    expect(bridge.joinArguments, containsPair('prioritizeFrameRate', true));

    bridge.emit({'type': 'sending', 'on': true});
    expect(live.state, NosmaiLiveState.live);
    expect(live.isLive, isTrue);

    await live.stop();
    expect(bridge.calls, contains('leave:true'));
    expect(live.state, NosmaiLiveState.stopped);
    expect(live.error, isNull);
    expect(states, containsAllInOrder([NosmaiLiveState.connecting, NosmaiLiveState.live, NosmaiLiveState.stopped]));
  });

  test('can keep the session open for viewers on stop', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge, endSessionOnStop: false);
    await live.start();
    await live.stop();
    expect(bridge.calls, contains('leave:false'));
  });

  test('rejects a viewer token before contacting Zoom', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge, token: jwt(role: 0));
    await expectLater(live.start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'invalid_token')));
    expect(bridge.calls, isNot(contains('join')));
    expect(live.state, NosmaiLiveState.failed);
  });

  test('rejects a token for another session or an expired token', () async {
    await expectLater(broadcaster(FakeBridge(), token: jwt(session: 'other')).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.message, 'message', contains('"other"'))));
    await expectLater(
        broadcaster(FakeBridge(), token: jwt(expires: testNow.subtract(const Duration(minutes: 1)))).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.message, 'message', contains('expired'))));
  });

  test('requires NosmaiZoomLive.initialize', () async {
    await expectLater(broadcaster(FakeBridge(), ready: false).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'not_initialized')));
  });

  test('needs the microphone only when publishing audio', () async {
    await expectLater(broadcaster(FakeBridge(microphone: false)).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'permission_denied')));
    final bridge = FakeBridge(microphone: false);
    final live = broadcaster(bridge, publishAudio: false);
    await live.start();
    expect(bridge.joinArguments, containsPair('micMuted', true));
    expect(live.micMuted, isTrue);
    await live.stop();
  });

  test('surfaces native join errors with their code', () async {
    final bridge = FakeBridge(
        joinError: PlatformException(code: 'already_active', message: 'Another Zoom session is active'));
    final live = broadcaster(bridge);
    await expectLater(
        live.start(),
        throwsA(isA<NosmaiLiveException>()
            .having((e) => e.code, 'code', 'already_active')
            .having((e) => e.message, 'message', contains('Another Zoom session'))));
    expect(live.state, NosmaiLiveState.failed);
    expect(bridge.calls, isNot(contains('leave:true')));
  });

  test('fails when Zoom reports a fatal error while joining', () async {
    final bridge = FakeBridge(autoJoin: false);
    final live = broadcaster(bridge);
    final starting = live.start();
    await Future<void>.delayed(Duration.zero);
    bridge.emit({'type': 'error', 'code': 2003, 'message': 'Join failed', 'fatal': true});
    await expectLater(starting, throwsA(isA<NosmaiLiveException>().having((e) => e.message, 'message', 'Join failed')));
    expect(live.state, NosmaiLiveState.failed);
    expect(live.error, 'Join failed');
  });

  test('times out when Zoom never confirms the join', () async {
    final bridge = FakeBridge(autoJoin: false);
    final live = NosmaiLiveBroadcaster(
      credentials: NosmaiLiveCredentials(token: jwt(), userName: 'Host'),
      session: const NosmaiLiveSession('stream'),
      bridge: bridge,
      nosmaiReady: () => true,
      clock: () => testNow,
      joinTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(live.start(), throwsA(isA<NosmaiLiveException>().having((e) => e.message, 'message', contains('timed out'))));
    expect(bridge.calls, contains('leave:true'));
  });

  test('fails when removed from the session while live', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    await live.start();
    bridge.emit({'type': 'sending', 'on': true});
    bridge.emit({'type': 'left', 'reason': 'KickByHost'});
    await Future<void>.delayed(Duration.zero);
    expect(live.state, NosmaiLiveState.failed);
    expect(live.error, contains('Removed'));
  });

  test('mutes, pauses in the background and reports reconnecting', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    await live.start();
    bridge.emit({'type': 'sending', 'on': true});

    live.setMicMuted(true);
    live.setVideoMuted(true);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls, containsAll(['mic:true', 'video:true']));
    expect(live.micMuted && live.videoMuted, isTrue);

    live.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(live.state, NosmaiLiveState.paused);
    live.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls, containsAllInOrder(['foreground:false', 'foreground:true']));
    expect(live.state, NosmaiLiveState.live);

    bridge.emit({'type': 'reconnecting'});
    expect(live.state, NosmaiLiveState.reconnecting);
    bridge.emit({'type': 'joined'});
    expect(live.state, NosmaiLiveState.live);
    await live.stop();
  });

  test('a broadcaster starts once', () async {
    final live = broadcaster(FakeBridge());
    await live.start();
    expect(live.start, throwsStateError);
    await live.stop();
  });
}
