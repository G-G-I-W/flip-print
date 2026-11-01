import 'package:flutter/material.dart';

import 'home_shell.dart';
import 'theme.dart';
import 'widgets.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.ready});

  /// Completes when app data has loaded.
  final Future<void> ready;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.wait([
      widget.ready,
      Future<void>.delayed(const Duration(milliseconds: 1400)),
    ]).then((_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 400),
          pageBuilder: (_, _, _) => const HomeShell(),
          transitionsBuilder: (_, a, _, child) =>
              FadeTransition(opacity: a, child: child),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Brand.gradient),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _WavePainter())),
            SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  const FlipLogo(size: 110),
                  const SizedBox(height: 28),
                  const Wordmark(size: 46, color: Colors.white),
                  const SizedBox(height: 18),
                  Text(
                    'Print Smart\nGet Duplex Results',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 18,
                      height: 1.4,
                    ),
                  ),
                  const Spacer(flex: 4),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FlutterLogo(size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Powered by Flutter',
                        style: TextStyle(
                          color: Brand.navy,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final back = Path()
      ..moveTo(0, s.height * 0.8)
      ..quadraticBezierTo(
        s.width * 0.3,
        s.height * 0.72,
        s.width * 0.6,
        s.height * 0.8,
      )
      ..quadraticBezierTo(
        s.width * 0.85,
        s.height * 0.86,
        s.width,
        s.height * 0.78,
      )
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(
      back,
      Paint()..color = Colors.white.withValues(alpha: 0.25),
    );
    final front = Path()
      ..moveTo(0, s.height * 0.86)
      ..quadraticBezierTo(
        s.width * 0.4,
        s.height * 0.8,
        s.width * 0.7,
        s.height * 0.87,
      )
      ..quadraticBezierTo(
        s.width * 0.9,
        s.height * 0.91,
        s.width,
        s.height * 0.88,
      )
      ..lineTo(s.width, s.height)
      ..lineTo(0, s.height)
      ..close();
    canvas.drawPath(front, Paint()..color = const Color(0xFFEAF2FF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
