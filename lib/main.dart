import 'package:flutter/material.dart';

import 'data/store.dart';
import 'ui/splash_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final ready = AppStore.instance.load();
  runApp(FlipPrintApp(ready: ready));
}

class FlipPrintApp extends StatelessWidget {
  const FlipPrintApp({super.key, required this.ready});

  final Future<void> ready;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FlipPrint',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: SplashScreen(ready: ready),
    );
  }
}
