import 'package:flutter/services.dart';

/// Calls into the plugin's native code over the `ffo_probe` method channel.
class FfoProbe {
  static const MethodChannel _channel = MethodChannel('ffo_probe');

  /// The platform version reported by the native side, e.g. `Android 16`.
  static Future<String> platformVersion() async {
    final version = await _channel.invokeMethod<String>('getPlatformVersion');
    return version ?? 'unknown';
  }
}
