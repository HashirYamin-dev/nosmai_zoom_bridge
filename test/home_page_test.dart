import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zoom_bridge/main.dart';
import 'package:nosmai_zoom_bridge/src/config.dart';

void main() {
  testWidgets('home shows both roles and flags a missing token', (tester) async {
    await tester.pumpWidget(const NosmaiZoomApp(config: AppConfig(sessionName: 'room')));
    expect(find.text('Host (Nosmai filters → Zoom)'), findsOneWidget);
    expect(find.text('Viewer'), findsOneWidget);
    expect(find.textContaining('broadcaster token is empty'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
  });
}
