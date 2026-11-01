import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Printer with a circular "flip" arrow — the FlipPrint mark.
class FlipLogo extends StatelessWidget {
  const FlipLogo({super.key, this.size = 96, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.25,
      height: size,
      child: Stack(
        children: [
          Icon(Icons.print_rounded, size: size, color: color),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.all(size * 0.04),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color == Colors.white ? Brand.blue : Colors.white,
              ),
              child: Icon(Icons.sync_rounded, size: size * 0.46, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// "FlipPrint" wordmark: Flip in [color], Print in sky blue.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 22, this.color = Brand.navy});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Flip',
            style: TextStyle(color: color),
          ),
          TextSpan(
            text: 'Print',
            style: TextStyle(
              color: color == Colors.white ? Brand.sky : Brand.blue,
            ),
          ),
        ],
      ),
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
      ),
    );
  }
}

/// Ink-tank printer drawn with shapes, labelled with the selected printer.
class PrinterIllustration extends StatelessWidget {
  const PrinterIllustration({
    super.key,
    required this.label,
    this.height = 170,
  });

  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: AspectRatio(
        aspectRatio: 1.6,
        child: CustomPaint(painter: _PrinterPainter(label)),
      ),
    );
  }
}

class _PrinterPainter extends CustomPainter {
  _PrinterPainter(this.label);
  final String label;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final body = const Color(0xFF2B2F3A);
    final bodyTop = const Color(0xFF3A3F4C);

    // Glow + floor shadow.
    canvas.drawCircle(
      Offset(w * 0.5, h * 0.52),
      math.min(w * 0.46, h * 0.48),
      Paint()..color = Brand.tint,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.48, h * 0.93),
        width: w * 0.8,
        height: h * 0.08,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.12),
    );

    // Paper sticking out of the rear feeder.
    final rear = Path()
      ..moveTo(w * 0.27, h * 0.33)
      ..lineTo(w * 0.31, h * 0.06)
      ..lineTo(w * 0.62, h * 0.06)
      ..lineTo(w * 0.64, h * 0.33)
      ..close();
    canvas.drawPath(rear, Paint()..color = Colors.white);
    canvas.drawPath(
      rear,
      Paint()
        ..color = const Color(0xFFD5DDEC)
        ..style = PaintingStyle.stroke,
    );

    // Main body.
    final main = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.12, h * 0.3, w * 0.62, h * 0.52),
      Radius.circular(w * 0.03),
    );
    canvas.drawRRect(main, Paint()..color = body);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.12, h * 0.3, w * 0.62, h * 0.1),
        Radius.circular(w * 0.03),
      ),
      Paint()..color = bodyTop,
    );

    // Ink tank unit on the right.
    final tank = RRect.fromRectAndRadius(
      Rect.fromLTWH(w * 0.72, h * 0.42, w * 0.16, h * 0.4),
      Radius.circular(w * 0.02),
    );
    canvas.drawRRect(tank, Paint()..color = body);
    const inks = [Colors.black87, Colors.cyan, Colors.pinkAccent, Colors.amber];
    for (var i = 0; i < 4; i++) {
      final x = w * (0.74 + i * 0.035);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, h * 0.5, w * 0.022, h * 0.26),
          Radius.circular(w * 0.006),
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.18),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, h * 0.6, w * 0.022, h * 0.16),
          Radius.circular(w * 0.006),
        ),
        Paint()..color = inks[i],
      );
    }

    // Output slot + printed sheet.
    canvas.drawRect(
      Rect.fromLTWH(w * 0.2, h * 0.66, w * 0.46, h * 0.025),
      Paint()..color = Colors.black,
    );
    final sheet = Path()
      ..moveTo(w * 0.22, h * 0.68)
      ..lineTo(w * 0.64, h * 0.68)
      ..lineTo(w * 0.7, h * 0.9)
      ..lineTo(w * 0.16, h * 0.9)
      ..close();
    canvas.drawPath(sheet, Paint()..color = Colors.white);
    final line = Paint()
      ..color = Brand.blueLight.withValues(alpha: 0.6)
      ..strokeWidth = h * 0.012
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 4; i++) {
      final y = h * (0.73 + i * 0.04);
      final inset = (y - h * 0.68) / (h * 0.22) * w * 0.06;
      canvas.drawLine(
        Offset(w * 0.27 - inset, y),
        Offset(w * (i == 3 ? 0.45 : 0.6) + inset, y),
        line,
      );
    }

    // Label.
    final tp = TextPainter(
      text: TextSpan(
        text: label.toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.85),
          fontSize: h * 0.055,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: w * 0.5);
    tp.paint(canvas, Offset(w * 0.43 - tp.width / 2, h * 0.47));
  }

  @override
  bool shouldRepaint(_PrinterPainter old) => old.label != label;
}

/// Circular progress ring with a printer icon in the middle.
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.value,
    this.size = 180,
    this.icon = Icons.print_rounded,
    this.color = Brand.blue,
  });

  final double value;
  final double size;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0, 1)),
      duration: const Duration(milliseconds: 500),
      builder: (context, v, _) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(v, color),
          child: Center(
            child: Container(
              width: size * 0.56,
              height: size * 0.56,
              decoration: const BoxDecoration(
                color: Brand.tint,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: size * 0.28, color: Brand.navy),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color);
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    canvas.drawArc(
      r,
      0,
      math.pi * 2,
      false,
      Paint()
        ..color = Brand.tint
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color;
}

/// Light-blue info box with an icon.
class InfoBox extends StatelessWidget {
  const InfoBox({
    super.key,
    required this.child,
    this.icon = Icons.info_rounded,
    this.color = Brand.blue,
    this.background = Brand.tint,
  });

  final Widget child;
  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: DefaultTextStyle.merge(
              style: TextStyle(
                color: color == Brand.blue ? Brand.navy : null,
                height: 1.4,
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// Square-ish tile with an icon and a label (home quick actions).
class ActionTile extends StatelessWidget {
  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Brand.tint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Brand.blue),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Section label used on settings-style screens.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: Brand.grey,
        letterSpacing: 0.8,
      ),
    ),
  );
}
