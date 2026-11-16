import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nosmai_zoom_live/nosmai_zoom_live.dart';

import 'config.dart';
import 'stats_overlay.dart';

/// Full-screen Nosmai preview; Start Live publishes exactly that processed
/// video to the Zoom session. Nosmai owns the camera the whole time.
class HostPage extends StatefulWidget {
  const HostPage({super.key, required this.config, required this.sessionName, required this.userName, this.token = ''});

  final AppConfig config;
  final String sessionName;
  final String userName;
  final String token;

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  final _nosmai = NosmaiZoomLive.effects;
  NosmaiLiveBroadcaster? _live;

  bool _nosmaiReady = false;
  bool _cameraReady = false;
  bool _closing = false;
  bool _starting = false;
  String? _fatal;
  String _status = 'Starting…';
  bool _micMuted = false;
  bool _showStats = true;
  List<NosmaiFilter> _filters = const [];
  String? _activeFilter;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final permissions = await NosmaiZoomLive.requestPermissions();
      if (!permissions.camera) throw StateError('Camera permission is required to host.');
      if (!permissions.microphone) _micMuted = true;
      await NosmaiZoomLive.initialize(
        androidLicenseKey: widget.config.nosmaiLicenseKey,
        iosLicenseKey: widget.config.iosLicenseKey,
      );
      if (!mounted) return;
      setState(() {
        _nosmaiReady = true;
        _status = 'Opening camera…';
      });
    } on NosmaiLiveException catch (e) {
      if (mounted) setState(() => _fatal = e.message);
    } catch (e) {
      if (mounted) setState(() => _fatal = '$e');
    }
  }

  Future<void> _onCameraReady() async {
    // Nosmai calls this again after every camera switch; only the first one matters here.
    if (!mounted || _closing || _cameraReady) return;
    setState(() {
      _cameraReady = true;
      _status = 'Preview ready';
    });
    await _loadFilters();
  }

  Future<void> _loadFilters() async {
    final found = <NosmaiFilter>[];
    try {
      found.addAll(await _nosmai.getLocalFilters());
    } catch (e) {
      debugPrint('[NosmaiZoomExample] local filters: $e');
    }
    try {
      found.addAll(await _nosmai.getCloudFilters(page: 1, limit: 30));
    } catch (e) {
      debugPrint('[NosmaiZoomExample] cloud filters: $e');
    }
    if (mounted) setState(() => _filters = found);
  }

  Future<void> _applyFilter(NosmaiFilter? filter) async {
    if (_applying || !_cameraReady) return;
    setState(() => _applying = true);
    try {
      if (filter == null) {
        await _nosmai.clearAll();
        _activeFilter = null;
      } else {
        var path = filter.path;
        if (filter.type == 'cloud' && (!filter.isDownloaded || path.isEmpty)) {
          setState(() => _status = 'Downloading ${filter.displayName}…');
          final result = await _nosmai.downloadCloudFilter(filter.cloudIdentifier);
          path = result['path']?.toString() ?? '';
        }
        if (path.isEmpty) throw StateError('No local .nosmai path');
        if (!await _nosmai.applyEffect(path)) throw StateError('Nosmai rejected the package');
        _activeFilter = filter.id;
      }
      _status = filter == null ? 'Filters cleared' : 'Applied ${filter.displayName}';
    } catch (e) {
      _status = 'Filter failed: $e';
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _toggleLive() async {
    final current = _live;
    if (current != null && current.state.isActive) {
      await _stopLive();
      return;
    }
    setState(() {
      _starting = true;
      _status = 'Getting token…';
    });
    try {
      final token = await resolveToken(
        config: widget.config,
        host: true,
        sessionName: widget.sessionName,
        userName: widget.userName,
        pasted: widget.token,
      );
      if (!mounted) return;
      final live = NosmaiLiveBroadcaster(
        credentials: NosmaiLiveCredentials(token: token, userName: widget.userName),
        session: NosmaiLiveSession(widget.sessionName, password: widget.config.sessionPassword),
        // Hold 30 FPS even when the phone reports serious heat (the default caps it at 15).
        video: const NosmaiLiveVideoConfig(
          resolution: NosmaiLiveResolution.p720,
          fps: 30,
          adaptToThermalState: false,
        ),
      )..addListener(_onLiveChanged);
      live.setMicMuted(_micMuted);
      setState(() {
        _live?.dispose();
        _live = live;
        _status = 'Joining ${widget.sessionName}…';
      });
      await live.start();
    } on TokenException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } on NosmaiLiveException catch (e) {
      if (mounted) setState(() => _status = '${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stopLive() async {
    final live = _live;
    if (live == null) return;
    setState(() => _status = 'Stopping…');
    await live.stop();
  }

  void _onLiveChanged() {
    final live = _live;
    if (!mounted || live == null) return;
    setState(() {
      _status = switch (live.state) {
        NosmaiLiveState.connecting => 'Joining ${widget.sessionName}…',
        NosmaiLiveState.live => 'LIVE in ${widget.sessionName}',
        NosmaiLiveState.reconnecting => 'Reconnecting…',
        NosmaiLiveState.paused => 'Paused in background',
        NosmaiLiveState.stopping => 'Stopping…',
        NosmaiLiveState.stopped => 'Live ended',
        NosmaiLiveState.failed => 'Failed: ${live.error}',
        _ => _status,
      };
    });
  }

  void _toggleMic() {
    setState(() => _micMuted = !_micMuted);
    _live?.setMicMuted(_micMuted);
  }

  Future<void> _exit() async {
    if (_closing) return;
    setState(() => _closing = true);
    await _live?.stop();
    try {
      if (_nosmai.isInitialized) await _nosmai.endCameraSession();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _live?.removeListener(_onLiveChanged);
    _live?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = _live;
    final isLive = live?.state == NosmaiLiveState.live;
    final active = live?.state.isActive ?? false;
    final busy = _starting || live?.state == NosmaiLiveState.stopping;
    final warning = live?.warning;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          if (_fatal != null)
            Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_fatal!, textAlign: TextAlign.center)))
          // Stays mounted while closing: Nosmai requires endCameraSession before removal.
          else if (_nosmaiReady)
            // Show the whole 9:16 frame, exactly what viewers receive. Filling a taller screen
            // (iOS aspect-fill) would crop the sides and make the preview look zoomed in.
            Center(
              child: AspectRatio(
                aspectRatio: 9 / 16,
                child: NosmaiCameraPreview(
                  onInitialized: _onCameraReady,
                  onError: (msg) {
                    if (mounted) setState(() => _status = 'Camera error: $msg');
                  },
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(children: [
                  IconButton.filledTonal(onPressed: _exit, icon: const Icon(Icons.arrow_back)),
                  const SizedBox(width: 8),
                  if (isLive) const Chip(label: Text('LIVE'), backgroundColor: Colors.red, visualDensity: VisualDensity.compact),
                  const Spacer(),
                  IconButton.filledTonal(
                    tooltip: 'Stats',
                    onPressed: () => setState(() => _showStats = !_showStats),
                    icon: Icon(_showStats ? Icons.speed : Icons.speed_outlined),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Microphone',
                    onPressed: _toggleMic,
                    icon: Icon(_micMuted ? Icons.mic_off : Icons.mic),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Switch camera',
                    onPressed: _cameraReady ? () => _nosmai.switchCamera() : null,
                    icon: const Icon(Icons.cameraswitch),
                  ),
                ]),
              ),
              if (_showStats && live != null && active)
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(padding: const EdgeInsets.all(8), child: StatsOverlay(stats: live.stats, host: true)),
                ),
              const Spacer(),
              _filterStrip(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(warning != null && active ? '$_status\n$warning' : _status,
                    maxLines: 3, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: active ? FilledButton.styleFrom(backgroundColor: Colors.red) : null,
                    onPressed: _cameraReady && !busy && !_closing ? _toggleLive : null,
                    icon: busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(active ? Icons.stop_circle : Icons.sensors),
                    label: Text(active ? 'Stop Live' : 'Start Live'),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _filterStrip() {
    Widget chip(String label, bool selected, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ChoiceChip(label: Text(label), selected: selected, onSelected: onTap == null ? null : (_) => onTap()),
        );
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          chip('None', _activeFilter == null, _cameraReady && !_applying ? () => _applyFilter(null) : null),
          for (final filter in _filters)
            chip(filter.displayName.isNotEmpty ? filter.displayName : filter.name, _activeFilter == filter.id,
                _cameraReady && !_applying ? () => _applyFilter(filter) : null),
        ],
      ),
    );
  }
}
