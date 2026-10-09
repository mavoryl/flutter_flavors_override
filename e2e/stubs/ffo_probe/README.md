# ffo_probe (stub)

No-op stub of `../../plugins/ffo_probe` for the `flutter_flavor_overrides`
end-to-end suite. It keeps the plugin's `name:` and Dart API but has no
`flutter: plugin:` section, so a flavor that resolves to it builds without the
plugin's native code. `FfoProbe.platformVersion()` returns `'stub'`.
