import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

import 'fakes.dart';

void main() {
  test('decodes Zoom token claims', () {
    final token = NosmaiZoomToken.tryParse(jwt(session: 'abc', role: 0));
    expect(token?.sessionName, 'abc');
    expect(token?.roleType, 0);
    expect(token?.appKey, 'key');
    expect(token?.expiresAt, testNow.add(const Duration(hours: 2)));
    expect(NosmaiZoomToken.tryParse('not.a.jwt'), isNull);
    expect(NosmaiZoomToken.tryParse('nope'), isNull);
  });

  test('checks the token against the session and role', () {
    String? problem(String token, {bool broadcaster = true}) =>
        NosmaiZoomToken.problemFor(token, sessionName: 'stream', broadcaster: broadcaster, now: testNow);
    expect(problem(jwt()), isNull);
    expect(problem(jwt(role: 0), broadcaster: false), isNull);
    expect(problem(''), contains('empty'));
    expect(problem('x.y.z'), contains('not a JWT'));
    expect(problem(jwt(role: 0)), contains('role_type 0'));
    expect(problem(jwt(session: 'other')), contains('"other"'));
    expect(problem(jwt(expires: testNow)), contains('expired'));
  });

  test('validates sessions and credentials', () {
    expect(const NosmaiLiveSession('stream').validate(), isNull);
    expect(const NosmaiLiveSession(' ').validate(), isNotNull);
    expect(NosmaiLiveSession('x' * 201).validate(), contains('200'));
    expect(const NosmaiLiveSession('s', password: '12345678901').validate(), contains('10'));
    const session = NosmaiLiveSession('stream');
    expect(NosmaiLiveCredentials(token: jwt(), userName: '').validate(session: session, broadcaster: true),
        contains('userName'));
    expect(NosmaiLiveCredentials(token: jwt(), userName: 'Host').toString(), isNot(contains('.')));
  });

  test('presets map to Zoom frame sizes', () {
    expect(NosmaiLiveVideoConfig.low.resolution.longSide, 640);
    expect(NosmaiLiveVideoConfig.standard.resolution.longSide, 960);
    expect(NosmaiLiveVideoConfig.standard.fps, 24);
    expect(NosmaiLiveVideoConfig.hd.resolution.longSide, 1280);
    expect(NosmaiLiveVideoConfig.hd.fps, 30);
  });

  test('parses native stats', () {
    final stats = NosmaiLiveStats.fromNative({
      'zoom': {'inSession': true, 'fps': 29, 'width': 720, 'height': 1280, 'bitrateKbps': 1500,
        'latencyMs': 80, 'lossPercent': 0.5, 'network': 'Good', 'participants': 3},
      'source': {'framesIn': 300, 'sent': 290, 'dropped': 2, 'inputFps': 30.1, 'txFps': 29.7, 'convertMsAvg': 1.25,
        'transport': 'texture', 'lastError': ''},
      'process': {'cpuPercent': 41.5, 'rssMb': 310.2},
    });
    expect(stats.width, 720);
    expect(stats.fps, 29);
    expect(stats.lossPercent, 0.5);
    expect(stats.participants, 3);
    expect(stats.framesFromNosmai, 300);
    expect(stats.framesSent, 290);
    expect(stats.nosmaiFps, 30.1);
    expect(stats.sendFps, 29.7);
    expect(stats.transport, 'texture');
    expect(stats.cpuPercent, 41.5);
    expect(stats.memoryMb, 310.2);
    expect(NosmaiLiveStats.fromNative(null).fps, 0);
  });
}
