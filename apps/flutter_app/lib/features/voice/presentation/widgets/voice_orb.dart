import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../../domain/voice/voice_session_state.dart';

/// Central voice visualisation.
///
/// Motion is driven only by real signals: the orb's size follows the live
/// audio [level] while listening/speaking, and a spinner runs only while the
/// session is genuinely waiting (connecting, reconnecting, processing). Idle,
/// disconnected and error states are static.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.phase, required this.level, this.size = 240});

  final VoicePhase phase;
  final double level;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _spinner = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  static bool _isWaiting(VoicePhase phase) =>
      phase == VoicePhase.connecting || phase == VoicePhase.reconnecting || phase == VoicePhase.processing;

  @override
  void initState() {
    super.initState();
    _syncSpinner();
  }

  @override
  void didUpdateWidget(VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _syncSpinner();
  }

  void _syncSpinner() {
    if (_isWaiting(widget.phase)) {
      if (!_spinner.isAnimating) _spinner.repeat();
    } else {
      _spinner.stop();
    }
  }

  @override
  void dispose() {
    _spinner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (widget.phase) {
      VoicePhase.disconnected => scheme.outline,
      VoicePhase.connecting || VoicePhase.reconnecting => scheme.primary.withValues(alpha: 0.7),
      VoicePhase.idle || VoicePhase.listening => scheme.primary,
      VoicePhase.processing => scheme.secondary,
      VoicePhase.speaking => scheme.tertiary,
      VoicePhase.interrupted => scheme.tertiary.withValues(alpha: 0.75),
      VoicePhase.error => scheme.error,
    };

    return Semantics(
      label: 'Voice status: ${widget.phase.name}',
      child: SizedBox.square(
        dimension: widget.size,
        // Smooths level updates (~30/s from the audio pipeline) without
        // animating when the level does not change.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: widget.phase.usesAudioLevel ? widget.level : 0),
          duration: const Duration(milliseconds: 90),
          builder: (context, level, _) => AnimatedBuilder(
            animation: _spinner,
            builder: (context, _) => CustomPaint(
              painter: _OrbPainter(
                color: color,
                highlight: Color.lerp(color, Colors.white, 0.45)!,
                level: level,
                spin: _isWaiting(widget.phase) ? _spinner.value : null,
                dimmed: widget.phase == VoicePhase.disconnected,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.color,
    required this.highlight,
    required this.level,
    required this.spin,
    required this.dimmed,
  });

  final Color color;
  final Color highlight;
  final double level;
  final double? spin;
  final bool dimmed;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseRadius = size.shortestSide * 0.3;
    final radius = baseRadius * (1 + level * 0.3);

    // Soft halo that grows with the audio level.
    final haloRadius = radius * (1.35 + level * 0.25);
    canvas.drawCircle(
      center,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: dimmed ? 0.12 : 0.32),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: haloRadius)),
    );

    // Core sphere.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.1,
          colors: dimmed ? [color.withValues(alpha: 0.55), color.withValues(alpha: 0.35)] : [highlight, color],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    // Progress arc while waiting on the network or the model.
    final spinValue = spin;
    if (spinValue != null) {
      final ringRadius = baseRadius * 1.28;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        spinValue * 2 * math.pi,
        math.pi * 0.6,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.color != color || old.level != level || old.spin != spin || old.dimmed != dimmed;
}
