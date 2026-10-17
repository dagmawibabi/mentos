import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../net/market/market.dart';
import '../../widgets/ui.dart';
import 'market_kit.dart';

/// Measures this phone live, step by step, before it is offered for rent.
class DeviceCheckScreen extends ConsumerStatefulWidget {
  const DeviceCheckScreen({super.key});

  @override
  ConsumerState<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends ConsumerState<DeviceCheckScreen> with SingleTickerProviderStateMixin {
  final _steps = <String, ProbeStep>{};
  Map<String, dynamic>? _result;
  StreamSubscription<ProbeStep>? _sub;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _run() {
    final m = ref.read(marketProvider);
    if (m == null || _running) return;
    setState(() {
      _running = true;
      _steps.clear();
      _result = null;
    });
    _sub = m.runDiagnostics().listen(
      (s) {
        if (!mounted) return;
        setState(() {
          if (s.id == 'done') {
            _result = s.result;
          } else {
            _steps[s.id] = s;
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _running = false);
      },
      onError: (Object e) {
        if (mounted) {
          setState(() => _running = false);
          toast(context, friendly(e));
        }
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final mc = MarketColors(p);
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Device check')),
      body: ListView(
        padding: const EdgeInsets.all(Space.gutter),
        children: [
          Center(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) => Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: mc.blueSoft,
                  boxShadow: [
                    if (_running)
                      BoxShadow(color: mc.blue.withValues(alpha: .25 * _pulse.value), blurRadius: 40, spreadRadius: 10 * _pulse.value),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(r == null ? '…' : '${r['score']}', style: Txt.display(mc.blue)),
                    Text(r == null ? 'MEASURING' : 'SCORE', style: Txt.label(p.muted)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.xl),
          for (final id in const ['device', 'cpu1', 'cpuN', 'ram', 'disk', 'net'])
            _StepRow(step: _steps[id], fallback: _labelFor(id)),
          if (r != null) ...[
            const SizedBox(height: Space.lg),
            MCard(
              color: p.accentSoft,
              border: false,
              child: Text(
                'Measured on this device just now. When you offer resources, these numbers travel with your listing '
                'so renters know what to expect. Renters verify the work itself: storage by audits, compute by checking results.',
                style: Txt.small(p.inkSoft),
              ),
            ),
            const SizedBox(height: Space.lg),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: () => context.pushReplacement('/market/sell/${Kinds.resource}'),
              icon: const Icon(Icons.sell_outlined),
              label: const Text('Offer part of this phone'),
            ),
            const SizedBox(height: Space.sm),
            OutlinedButton(onPressed: _running ? null : _run, child: const Text('Run again')),
          ],
        ],
      ),
    );
  }

  String _labelFor(String id) => switch (id) {
    'device' => 'Device',
    'cpu1' => 'Single-core speed',
    'cpuN' => 'All cores',
    'ram' => 'Memory',
    'disk' => 'Storage',
    _ => 'Network path',
  };
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.fallback});
  final ProbeStep? step;
  final String fallback;
  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = step;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: s == null
                ? Icon(Icons.radio_button_unchecked_rounded, color: p.faint)
                : s.done
                    ? Icon(Icons.check_circle_rounded, color: p.accent)
                    : Padding(padding: const EdgeInsets.all(4), child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s?.label ?? fallback, style: Txt.bodyStrong(s == null ? p.muted : p.ink)),
                if (s?.value != null) Text(s!.value!, style: Txt.small(p.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
