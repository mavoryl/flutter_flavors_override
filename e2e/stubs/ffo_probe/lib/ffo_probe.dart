/// No-op stand-in for the `ffo_probe` plugin: same API, no native code.
class FfoProbe {
  /// Always `'stub'`: there is no platform side to ask.
  static Future<String> platformVersion() async => 'stub';
}
