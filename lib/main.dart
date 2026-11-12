import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

import 'src/config.dart';
import 'src/host_page.dart';
import 'src/viewer_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const NosmaiZoomApp());
}

class NosmaiZoomApp extends StatelessWidget {
  const NosmaiZoomApp({super.key, this.config = const AppConfig.fromEnvironment()});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nosmai × Zoom Live',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2D8CFF), brightness: Brightness.dark),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
      ),
      home: HomePage(config: config),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.config});

  final AppConfig config;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final _session = TextEditingController(text: widget.config.sessionName);
  final _name = TextEditingController(text: 'user${DateTime.now().millisecondsSinceEpoch % 10000}');
  final _token = TextEditingController();

  @override
  void dispose() {
    _session.dispose();
    _name.dispose();
    _token.dispose();
    super.dispose();
  }

  String? _tokenHint(bool host) {
    if (_token.text.trim().isNotEmpty || widget.config.tokenUrl.isNotEmpty) return null;
    return NosmaiZoomToken.problemFor(widget.config.tokenFor(host: host),
        sessionName: _session.text.trim(), broadcaster: host);
  }

  void _open(bool host) {
    final session = _session.text.trim();
    final name = _name.text.trim();
    if (session.isEmpty || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a session and display name.')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => host
          ? HostPage(config: widget.config, sessionName: session, userName: name, token: _token.text)
          : ViewerPage(config: widget.config, sessionName: session, userName: name, token: _token.text),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hostHint = _tokenHint(true);
    final viewerHint = _tokenHint(false);
    final source = widget.config.tokenUrl.isNotEmpty ? 'token server ${widget.config.tokenUrl}' : 'build-time tokens';
    return Scaffold(
      appBar: AppBar(title: const Text('Nosmai × Zoom Live')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _session,
          decoration: const InputDecoration(labelText: 'Session name (token tpc)'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name')),
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          decoration: const InputDecoration(labelText: 'Session JWT (optional override)'),
          maxLines: 1,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text('Token source: ${_token.text.trim().isNotEmpty ? 'pasted' : source}',
            style: Theme.of(context).textTheme.bodySmall),
        if (hostHint != null) Text('Host: $hostHint', style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
        if (viewerHint != null)
          Text('Viewer: $viewerHint', style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => _open(true),
          icon: const Icon(Icons.videocam),
          label: const Text('Host (Nosmai filters → Zoom)'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _open(false),
          icon: const Icon(Icons.live_tv),
          label: const Text('Viewer'),
        ),
      ]),
    );
  }
}
