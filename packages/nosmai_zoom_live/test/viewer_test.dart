import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NosmaiLiveViewer viewer(FakeBridge bridge, {String? token, String? hostUserName}) => NosmaiLiveViewer(
        credentials: NosmaiLiveCredentials(token: token ?? jwt(role: 0), userName: 'Viewer'),
        session: const NosmaiLiveSession('stream'),
        hostUserName: hostUserName,
        bridge: bridge,
        clock: () => testNow,
        statsInterval: const Duration(days: 1),
      );

  test('waits for the broadcaster, then plays its video', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge, hostUserName: 'Host');
    await watch.start();
    expect(bridge.joinArguments, containsPair('host', false));
    expect(bridge.joinArguments, containsPair('hostUserName', 'Host'));
    expect(bridge.calls, contains('permissions'));
    expect(watch.state, NosmaiLiveState.waitingForHost);
    expect(watch.hasVideo, isFalse);

    bridge.emit({'type': 'remoteVideo', 'userName': 'Host', 'on': true});
    expect(watch.state, NosmaiLiveState.live);
    expect(watch.hasVideo, isTrue);
    expect(watch.watchingUserName, 'Host');

    bridge.emit({'type': 'remoteVideo', 'userName': null, 'on': false});
    expect(watch.state, NosmaiLiveState.waitingForHost);

    watch.setSpeakerMuted(true);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls, contains('speaker:true'));

    await watch.stop();
    expect(bridge.calls, contains('leave:false'));
    expect(watch.state, NosmaiLiveState.stopped);
  });

  test('stops cleanly when the broadcaster ends the session', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge);
    await watch.start();
    bridge.emit({'type': 'left', 'reason': 'EndByHost'});
    await Future<void>.delayed(Duration.zero);
    expect(watch.state, NosmaiLiveState.stopped);
    expect(watch.endedByHost, isTrue);
    expect(watch.error, isNull);
  });

  test('rejects a host token', () async {
    final bridge = FakeBridge();
    await expectLater(viewer(bridge, token: jwt(role: 1)).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'invalid_token')));
    expect(bridge.calls, isNot(contains('join')));
  });

  test('non-fatal Zoom errors become warnings', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge);
    await watch.start();
    bridge.emit({'type': 'error', 'code': 1, 'message': 'Subscribe hiccup', 'fatal': false});
    expect(watch.warning, 'Subscribe hiccup');
    expect(watch.state, NosmaiLiveState.waitingForHost);
    await watch.stop();
  });
}
