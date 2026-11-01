import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps a print going while FlipPrint is in the background (Android
/// foreground service + notification). A no-op on other platforms.
class BackgroundPrint {
  static const _channel = MethodChannel('flipprint/print');
  static bool _running = false;

  static bool get _supported => Platform.isAndroid;

  /// Whether the user is looking at another app right now.
  static bool get inBackground =>
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  static Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod(method, args);
    } on PlatformException catch (_) {
      // Printing still works in the foreground without the service.
    }
  }

  /// Starts or refreshes the ongoing "Printing…" notification.
  static Future<void> update(
    String title,
    String text, {
    int progress = 0,
    int max = 0,
  }) {
    final method = _running ? 'update' : 'start';
    _running = true;
    return _call(method, {
      'title': title,
      'text': text,
      'progress': progress,
      'max': max,
    });
  }

  /// A heads-up notification with sound, e.g. "Flip the paper".
  static Future<void> alert(String title, String text) =>
      _call('alert', {'title': title, 'text': text});

  static Future<void> clearAlert() => _call('clearAlert');

  /// Ends the service. With [title], leaves a "finished" notification when
  /// the app is in the background.
  static Future<void> stop({String? title, String? text}) {
    if (!_running) return Future.value();
    _running = false;
    return _call('stop', {
      if (title != null && inBackground) 'title': title,
      if (text != null && inBackground) 'text': text,
    });
  }
}
