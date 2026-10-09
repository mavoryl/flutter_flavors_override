# ffo_probe

Test plugin for the `flutter_flavor_overrides` end-to-end suite. It has native
code on Android (`io.github.mavoryl.ffo_probe.FfoProbePlugin`) and iOS
(`FfoProbePlugin`, both a podspec and a `Package.swift`), so the e2e checks can
tell whether a build contains it.

`../../stubs/ffo_probe` is its no-op stub: the same `name:` and Dart API, no
native code.
