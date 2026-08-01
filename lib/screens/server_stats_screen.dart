import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_path.dart';
import '../services/server_probe.dart';
import '../services/session_controller.dart';

/// One server's vital signs, polled while this screen is on top.
///
/// **Nothing here runs in the background.** The poller starts when the screen
/// appears, stops when the app is backgrounded, and is disposed with the
/// route — there is no per-host watcher anywhere in the app, and a server the
/// user is not currently looking at is never contacted. That rule is the
/// reason the schedule lives in [ServerStatsPoller] rather than in this
/// `State`: it is testable there, and `server_probe_test.dart` holds it.
class ServerStatsScreen extends StatefulWidget {
  const ServerStatsScreen({super.key, required this.session});

  final SessionController session;

  @override
  State<ServerStatsScreen> createState() => _ServerStatsScreenState();
}

class _ServerStatsScreenState extends State<ServerStatsScreen>
    with WidgetsBindingObserver {
  late final ServerStatsPoller _poller;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _poller = ServerStatsPoller(
      // Through the session rather than captured once: a reconnect swaps the
      // transport underneath, and a poller holding the old one would probe a
      // socket nobody is listening on. See SessionController.adoptTransport.
      transport: () => widget.session.connection,
    );
    _changes = _poller.changes.listen((_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addObserver(this);
    _poller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The other half of "only while visible": a phone in a pocket is not
    // somebody watching a graph, and five seconds of exec channels a minute
    // is not something to spend a backgrounded app's radio on.
    if (state == AppLifecycleState.resumed) {
      _poller.start();
    } else {
      _poller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_changes?.cancel());
    unawaited(_poller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _poller.snapshot;
    final stats = snapshot.stats;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Server stats', style: TextStyle(fontSize: 16)),
            Text(
              widget.session.host.displayName,
              style: TextStyle(
                fontSize: 11.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh now',
            icon: _poller.isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _poller.isRefreshing
                ? null
                : () => unawaited(_poller.refresh()),
          ),
        ],
      ),
      body: SafeArea(
        child: stats == null
            ? _WholePanelState(
                error: snapshot.error,
                refreshing: _poller.isRefreshing,
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  // A failed refresh does not blank the panel; it says so
                  // above readings that are still the last known good ones.
                  if (snapshot.error != null)
                    _StaleBanner(message: snapshot.error!, at: snapshot.at),
                  _IdentityCard(stats: stats),
                  const SizedBox(height: 12),
                  _LoadCard(stats: stats, history: _poller.loadHistory),
                  const SizedBox(height: 12),
                  _MemoryCard(memory: stats.memory),
                  const SizedBox(height: 12),
                  _DiskCard(disk: stats.disk),
                ],
              ),
      ),
    );
  }
}

/// Shown only when *nothing* has been read yet — a first probe still in
/// flight, or a server that answered none of the commands.
class _WholePanelState extends StatelessWidget {
  const _WholePanelState({required this.error, required this.refreshing});

  final String? error;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    if (error == null && refreshing) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.monitor_heart_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              error ?? 'No readings yet.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message, this.at});

  final String message;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final at = this.at;
    final age = at == null ? null : DateTime.now().difference(at);
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_outlined,
              size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              age == null
                  ? message
                  : '$message Showing the reading from '
                      '${_formatAge(age)} ago.',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// A card with a title and rows. Every metric card shares it so a missing
/// metric looks the same wherever it happens.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// What a metric shows when the server did not give us a number we trust.
///
/// Per metric, never per panel: a BSD box with no `/proc` still shows its
/// disk, its load and its kernel, and says one quiet line about the one
/// thing it could not answer.
class _Unknown extends StatelessWidget {
  const _Unknown(this.what);

  final String what;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.remove_circle_outline,
            size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Could not read $what on this server.',
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.stats});

  final ServerStats stats;

  @override
  Widget build(BuildContext context) {
    final uptime = stats.uptime;
    final cpuCount = stats.cpuCount;
    return _Card(
      title: 'SYSTEM',
      icon: Icons.dns_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stats.hostname != null) _Row('Hostname', stats.hostname!),
          if (stats.kernel != null)
            _Row('Kernel', stats.kernel!)
          else
            const _Unknown('the kernel version'),
          if (uptime != null)
            _Row('Uptime', formatUptime(uptime))
          else
            const _Unknown('the uptime'),
          if (cpuCount != null)
            _Row('CPUs', '$cpuCount')
          else
            const _Unknown('the processor count'),
        ],
      ),
    );
  }
}

class _LoadCard extends StatelessWidget {
  const _LoadCard({required this.stats, required this.history});

  final ServerStats stats;
  final List<double> history;

  @override
  Widget build(BuildContext context) {
    final load = stats.load;
    return _Card(
      title: 'LOAD AVERAGE',
      icon: Icons.speed_outlined,
      child: load == null
          ? const _Unknown('the load average')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _LoadValue(
                      label: '1 min',
                      value: load.one,
                      cpus: stats.cpuCount,
                    ),
                    _LoadValue(
                      label: '5 min',
                      value: load.five,
                      cpus: stats.cpuCount,
                    ),
                    _LoadValue(
                      label: '15 min',
                      value: load.fifteen,
                      cpus: stats.cpuCount,
                    ),
                  ],
                ),
                if (history.length > 1) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 36,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: SparklinePainter(
                        values: history,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'One-minute load, this session only',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _LoadValue extends StatelessWidget {
  const _LoadValue({required this.label, required this.value, this.cpus});

  final String label;
  final double value;
  final int? cpus;

  @override
  Widget build(BuildContext context) {
    // Load is only meaningful against the core count — 4.0 is saturated on a
    // 4-core box and half idle on an 8-core one — so the colour is only
    // applied when we actually know how many cores there are.
    final saturated = cpus != null && cpus! > 0 && value >= cpus!;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value.toStringAsFixed(2),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: saturated ? Theme.of(context).colorScheme.error : null,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.memory});

  final MemoryUsage? memory;

  @override
  Widget build(BuildContext context) {
    final memory = this.memory;
    return _Card(
      title: 'MEMORY',
      icon: Icons.memory_outlined,
      child: memory == null
          ? const _Unknown('memory')
          : _UsageBar(
              used: memory.used,
              total: memory.total,
              fraction: memory.usedFraction,
              footnote: '${RemotePath.formatBytes(memory.available)} available',
            ),
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.disk});

  final DiskUsage? disk;

  @override
  Widget build(BuildContext context) {
    final disk = this.disk;
    return _Card(
      title: 'DISK',
      icon: Icons.storage_outlined,
      child: disk == null
          ? const _Unknown('disk usage')
          : _UsageBar(
              used: disk.used,
              total: disk.total,
              fraction: disk.usedFraction,
              footnote: '${RemotePath.formatBytes(disk.available)} available '
                  'on ${disk.mountPoint}',
            ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.used,
    required this.total,
    required this.fraction,
    required this.footnote,
  });

  final int used;
  final int total;
  final double? fraction;
  final String footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = this.fraction;
    // 90% is the point at which a full disk stops being a statistic and
    // becomes tonight's problem. Tertiary is the warm middle step between
    // primary (fine) and error (critical) — see the same three-tier
    // reasoning in `backup_screen.dart`'s passphrase-strength meter.
    final colour = fraction == null
        ? theme.colorScheme.primary
        : fraction >= 0.9
            ? theme.colorScheme.error
            : fraction >= 0.75
                ? theme.colorScheme.tertiary
                : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              RemotePath.formatBytes(used),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            Text(
              ' of ${RemotePath.formatBytes(total)}',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (fraction != null)
              Text(
                '${(fraction * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colour,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            backgroundColor:
                theme.colorScheme.onSurface.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(colour),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          footnote,
          style: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// A minimal line chart over the in-memory load history.
///
/// A `CustomPainter` rather than a charting package: `pubspec.yaml` is not
/// being touched for this phase, and a sparkline is thirty lines of
/// `lineTo`. It reads [values] as already-bounded — the poller caps the ring
/// buffer — so there is no windowing logic here.
class SparklinePainter extends CustomPainter {
  const SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0 || size.height <= 0) return;

    var max = 0.0;
    for (final value in values) {
      if (value > max) max = value;
    }
    // A flat line of zeros still draws along the bottom rather than dividing
    // by zero; the scale floor also stops a server idling at 0.01 from
    // rendering as a dramatic mountain range.
    final scale = max < 0.5 ? 0.5 : max;

    final step = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = step * i;
      final y = size.height - (values[i] / scale) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // The fill under the line, at low opacity, so the shape reads at a
    // glance on a small screen.
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()..color = color.withValues(alpha: 0.15),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(SparklinePainter oldDelegate) =>
      oldDelegate.values.length != values.length ||
      oldDelegate.color != color ||
      !_sameValues(oldDelegate.values, values);

  bool _sameValues(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// "6h 46m", "10d 3h", "45m". Pure, and exported so a test can pin it.
///
/// Days-and-hours or hours-and-minutes, never three units: the third one is
/// never what the reader wanted to know.
String formatUptime(Duration uptime) {
  final days = uptime.inDays;
  final hours = uptime.inHours % 24;
  final minutes = uptime.inMinutes % 60;

  if (days > 0) return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  if (hours > 0) return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  if (minutes > 0) return '${minutes}m';
  return 'less than a minute';
}

String _formatAge(Duration age) {
  if (age.inMinutes < 1) return '${age.inSeconds}s';
  if (age.inHours < 1) return '${age.inMinutes}m';
  return '${age.inHours}h';
}

/// Pushes the stats screen for [session].
Future<void> openServerStats(
  BuildContext context, {
  required SessionController session,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => ServerStatsScreen(session: session),
    ),
  );
}
