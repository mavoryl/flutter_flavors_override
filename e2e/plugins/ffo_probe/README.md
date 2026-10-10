# ffo_probe

Test plugin for the `flutter_flavor_overrides` end-to-end suite. It has native
code on Android (`io.github.mavoryl.ffo_probe.FfoProbePlugin`), iOS and macOS
(`FfoProbePlugin`, both a podspec and a `Package.swift` each) and Linux
(`libffo_probe_plugin.so`), so the e2e checks can tell whether a build
contains it. The macOS and Linux code also holds a marker string,
`ffo_probe_native_marker_macos` and `ffo_probe_native_marker_linux`, that the
checks look for in the built binaries.

`../../stubs/ffo_probe` is its no-op stub: the same `name:` and Dart API, no
native code.
