import 'package:ffo_probe/ffo_probe.dart';

/// What the feature shows: the probe's platform version, or `'stub'` in a
/// flavor where ffo_probe resolves to its stub.
Future<String> probeVersion() => FfoProbe.platformVersion();
