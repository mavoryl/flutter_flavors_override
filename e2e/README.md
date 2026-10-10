# End-to-end fixtures

Real Flutter builds that check the idea behind `flutter_flavor_overrides`: a
`pubspec_overrides.yaml` that swaps a plugin for a no-op stub keeps the
plugin's native code out of a flavor's Android, iOS, macOS and Linux build,
and leaving the file out brings it back.

None of this is part of the published package (`/e2e/` is in `.pubignore`) or
of the root package's analysis (`analysis_options.yaml` excludes it).

## Layout

```
e2e/
├── plugins/ffo_probe/   test plugin with native code (Android; iOS and macOS: podspec and
│                        Package.swift; Linux)
├── stubs/ffo_probe/     its no-op stub: same name and Dart API, no `flutter: plugin:`
├── single/              one app package that depends on ffo_probe
├── workspace/           pub workspace: app/ -> packages/feature/ -> ffo_probe
├── path_modules/        no workspace: app/ -> path: packages/feature/ -> ffo_probe
├── melos6/              melos 6, no workspace: app/ -> feature (linked by melos) -> ffo_probe
├── melos6_local/        melos 6, no workspace: app/ -> feature -> ffo_probe, both linked by melos
└── tool/
    ├── verify.sh              builds a fixture and checks the plugin's footprint
    ├── smoke_min_flutter.sh   pub-level smoke test on the oldest supported Flutter
    └── add_xcode_flavors.rb   adds the iOS and macOS flavor configurations and schemes
```

The package that depends on `ffo_probe` declares the override for `prod`, with
a path relative to its own pubspec:

```yaml
flavor_overrides:
  prod:
    ffo_probe:
      path: ../stubs/ffo_probe
```

`<fixture>/expected/prod/` holds the golden `pubspec_overrides.yaml` files
the CLI generates for `--flavor prod`, laid out as the fixture itself, with
paths relative to where each file goes. With a workspace there is one file at
the workspace root; without one, every local package that resolves gets its
own. `dev` has no overrides, so there is no `expected/dev/`. The unit test
`test/e2e_expected_test.dart` checks that the CLI writes exactly these files.
Generated overrides files are ignored by git; the ones under `expected/` are
tracked.

`melos6` is a melos 6 repository without a pub workspace: the root
`pubspec.yaml` has `melos: 6.3.3` as a dev dependency (run as `dart run
melos`, never activated globally), `melos.yaml` lists `app` and `packages/*`,
and the app depends on `feature: 0.0.1` by version, so only `melos bootstrap`
links it to `packages/feature`, through the app's `pubspec_overrides.yaml`.
That file then holds the entries of melos and of the CLI side by side, each
under its own marker comment. `melos6` has no iOS, macOS or Linux project.

`melos6_local` is the same, except that the plugin to swap is a melos package
itself: its `melos.yaml` lists `../*/ffo_probe` besides `app` and
`packages/*`, and `feature` depends on `ffo_probe: 0.0.1` by version, so
`melos bootstrap` links the plugin too. That glob matches the stub as well,
which has the plugin's name; melos refuses two packages with one name, so
`ignore:` leaves out `../stubs/*`. In `prod` the CLI takes melos's entry for
`ffo_probe` over: the name leaves melos's marker for ours, and `melos
bootstrap` then leaves the entry alone. It has no iOS, macOS or Linux project
either.

## Flavors

Each app has the flavors `dev` and `prod`:

- Android: `productFlavors` with dimension `env` in
  `android/app/build.gradle.kts`; `dev` has the application id suffix `.dev`.
- iOS and macOS: build configurations `Debug-<flavor>`, `Release-<flavor>`,
  `Profile-<flavor>` and shared schemes `dev` and `prod`, added by
  `tool/add_xcode_flavors.rb` (needs the `xcodeproj` gem, which ships with
  CocoaPods); `dev` has the bundle id suffix `.dev` (on macOS
  `$(inherited).dev`: the bundle id lives in `Runner/Configs/AppInfo.xcconfig`).
- Linux: none. Flutter has no flavors on Linux, `flutter build linux` takes no
  `--flavor`; the flavor only picks the overrides, so the CLI and the checks
  still tell `dev` from `prod`.

## Running

```bash
e2e/tool/verify.sh <single|workspace|path_modules|melos6|melos6_local> \
    <android|ios-cocoapods|ios-spm|macos-cocoapods|macos-spm|linux> <dev|prod>
```

The script never builds in the repository. It copies `e2e/` (the files a fresh
checkout would have) to a temporary directory and runs the CLI of this
repository there, `bin/flutter_flavor_overrides.dart --flavor <flavor>`, from
where a developer would: the app for `single` and `path_modules`, the root for
`workspace`, `melos6` and `melos6_local`. It passes the repository's package config to `dart`
explicitly: `dart run <file>` would first run `pub get` in the fixture, before
the overrides exist. Then it runs `flutter pub get` (at the workspace root for
`workspace`, in the app and the feature package for `path_modules`; `dart run
melos bootstrap` for `melos6` and `melos6_local`) and builds the app:

- `flutter build apk --release --flavor <flavor>`,
- `flutter build ios --release --flavor <flavor> --no-codesign` or
  `flutter build macos --release --flavor <flavor>`, after setting
  `flutter: config: enable-swift-package-manager:` in the copy of the app's
  pubspec (`false` for `*-cocoapods`, `true` for `*-spm`), so the machine's
  global `flutter config` does not matter, or
- `flutter build linux --release`, without `--flavor`.

Then it prints one `PASS`/`FAIL` line per check and exits with 0 only if all
passed. In `dev` the plugin must be found, in `prod` it must not:

- `.dart_tool/package_config.json` of every package that resolves points
  `ffo_probe` at the plugin (in `prod`: at the stub);
- `.flutter-plugins-dependencies` lists `ffo_probe` for the platform;
- the generated registrant registers `FfoProbePlugin`:
  `GeneratedPluginRegistrant.java` (Android), `.m` (iOS), `.swift` (macOS),
  `linux/flutter/generated_plugin_registrant.cc`; on Linux also
  `linux/flutter/generated_plugins.cmake` has `ffo_probe` in
  `FLUTTER_PLUGIN_LIST`;
- Android: the APK's dex has the class
  `io.github.mavoryl.ffo_probe.FfoProbePlugin` and the plugin's string
  `getPlatformVersion`;
- iOS and macOS with CocoaPods: `Podfile.lock` has `ffo_probe`, the app's
  `Frameworks` (`Runner.app/Frameworks`, `<app>.app/Contents/Frameworks`) has
  `ffo_probe.framework`;
- iOS and macOS with Swift Package Manager: the generated
  `FlutterGeneratedPluginSwiftPackage/Package.swift` lists `ffo_probe`;
- iOS and macOS: the app binary (`Runner.app/Runner`,
  `<app>.app/Contents/MacOS/<app>`) mentions `FfoProbePlugin` (the whole file
  is searched: with CocoaPods the name is in the binary's imports);
- macOS: the app bundle has the plugin's string
  `ffo_probe_native_marker_macos` (in `ffo_probe.framework` with CocoaPods, in
  the app binary with Swift Package Manager, which links the plugin
  statically);
- Linux: the bundle (`build/linux/<arch>/release/bundle`) has
  `lib/libffo_probe_plugin.so` and the plugin's string
  `ffo_probe_native_marker_linux`, and its binary needs
  `libffo_probe_plugin.so` and mentions `FfoProbePlugin`.

`melos6` runs on Android only and switches flavors in one copy, the way a
developer does: first the other flavor, then the requested one, each with the
CLI, `melos bootstrap`, the build and all the checks. Its app's
`pubspec_overrides.yaml` must start with the marker of melos
(`# melos_managed_dependency_overrides: feature`) and have ours
(`# flutter_flavor_overrides: ffo_probe`) in `prod`, none in `dev`; the app
must resolve `feature` to `packages/feature`.

`melos6_local` runs on Android only too, in one copy: `melos bootstrap` first,
which links the plugin, then the requested flavor, the other one, and the
requested one again. The first of them gets the CLI, `flutter pub get` in the
app instead of `melos bootstrap`, and the build, so only the app's
`package_config.json` is checked there. The others get the CLI, `melos
bootstrap` and the build. Some `pub get` has to follow the CLI: `flutter
build` skips its own while `pubspec.yaml` is older than `pubspec.lock` and
`package_config.json`, and does not look at `pubspec_overrides.yaml`
(Flutter 3.44.8, `flutter_tools/lib/src/dart/pub.dart`). On top of the `melos6` checks, melos's marker in
the app's file must list `ffo_probe` in `dev` and must not in `prod`.

Checks that do not depend on the flavor confirm the setup:

- the flavor was applied: the APK is `app-<flavor>-release.apk` with the
  flavor's application id; the iOS and macOS builds used the
  `Release-<flavor>` configuration and have the flavor's bundle id (Linux has
  no flavor to check);
- the iOS or macOS dependency manager is the requested one: with Swift Package
  Manager the generated plugins package depends on `FlutterFramework`, and
  neither `Podfile.lock` nor the app's `Frameworks` has `ffo_probe`; with
  CocoaPods the package depends on neither `FlutterFramework` nor `ffo_probe`.
  Without plugins (`prod`) Flutter does not run `pod install` at all. When
  `.flutter-plugins-dependencies` exists, its `swift_package_manager_enabled`
  for the platform is the requested value.

Options:

- `--golden` lays out the golden files instead of running the CLI: it
  removes every `pubspec_overrides.yaml` in the copy and copies
  `expected/<flavor>/` over the fixture. Not for `melos6_local`, whose first
  build needs the links of melos that this would remove.
- `--no-overrides` is a negative control, `prod` must then fail: the CLI runs
  with `--clean` instead of `--flavor` (with `--golden`: nothing is laid out).
- `--keep` keeps the temporary copy and prints its path.
- `--workdir DIR` reuses a kept copy: switch flavors in place, the way a
  developer would locally, e.g. `prod` and then `dev`.
- `--logs DIR` writes the pub and build logs to `DIR`.

Requirements: `flutter` and `dart` on `PATH`, `git`, `tar`, `unzip`,
`strings`. The CLI runs from the repository, which needs `dart pub get`; the
script runs it when `.dart_tool/package_config.json` is missing. Android: an
Android SDK (`$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Library/Android/sdk` or
`~/Android/Sdk`) with build-tools that have `dexdump` and `aapt2`. iOS and
macOS: macOS with Xcode and CocoaPods. Linux: a Linux machine with what
Flutter's Linux desktop builds need (`clang`, `cmake`, `ninja`, `pkg-config`,
the GTK 3 headers).

## Oldest supported Flutter

The fixtures come from the templates of Flutter 3.44, which older Flutter
releases cannot build. `tool/smoke_min_flutter.sh` covers the oldest one the
CLI supports, Flutter 3.22 (Dart 3.4), without a native build:

```bash
e2e/tool/smoke_min_flutter.sh [--keep]
```

With the Flutter on `PATH`, it creates an Android app in a temporary
directory next to copies of `plugins/` and `stubs/`, makes it depend on
`ffo_probe` with a `prod` override to the stub, and runs the CLI on that
Flutter's Dart (as a path dependency of a throwaway package: the repository's
own dev dependencies need a newer SDK). After `--flavor prod` and `flutter pub
get`, `package_config.json` points `ffo_probe` at the stub and neither
`.flutter-plugins-dependencies` nor `GeneratedPluginRegistrant.java` has the
plugin; after `--flavor dev`, the overrides file is gone and all three have it
again. That is the part that depends on the Flutter version: the native build
only consumes Flutter's plugin list. The plugin and the stub accept Dart 3.4
for this.

## CI

`.github/workflows/e2e.yml` runs on every push to `main` and every pull
request, on Flutter 3.44.8: `verify.sh <fixture> android dev` and `prod` for
all five fixtures on Linux; for the three without melos, one macOS job per
fixture and dependency manager (CocoaPods, Swift Package Manager) that builds
iOS and then macOS, `dev` and `prod` each, and one Linux job per fixture for
Linux desktop; and the smoke test on Flutter 3.22.3. `verify.sh` runs on macOS
and Linux alike. Windows desktop is not built.

## Fixture notes

- `ffo_probe` ships a consumer ProGuard rule that keeps its classes' names: R8
  renames classes in release builds, and the dex check looks the plugin up by
  name.
- The iOS deployment target is 15.0, and each app commits its `Podfile`
  (otherwise Flutter generates it on demand) to raise the pods' deployment
  target to 15.0 too: Xcode 27 rejects anything lower, while Flutter's
  templates and the `Flutter` pod still say 13.0. The `Podfile` also maps the
  flavor configurations to `:debug` and `:release`.
- The same on macOS with 12.0, the lowest Xcode 27 accepts (Flutter's
  templates say 10.15): in the project, in the committed `macos/Podfile`
  (with the same flavor mapping) and, through its `post_install`, for every
  pod. `macos/Flutter/Flutter-*.xcconfig` include the pods' xcconfig, as the
  iOS ones do: Flutter adds that include only when it sets up CocoaPods
  itself, and a Swift Package Manager build still runs `pod install` for the
  committed `Podfile`.
- The apps were created with `flutter create --platforms=android,ios --org
  io.github.mavoryl`, then `ruby e2e/tool/add_xcode_flavors.rb
  <app>/ios/Runner.xcodeproj`; `macos/` and `linux/` came later from
  `flutter create --platforms=macos,linux` (the same Flutter, the same org),
  followed by `ruby e2e/tool/add_xcode_flavors.rb <app>/macos/Runner.xcodeproj`.
- `ffo_probe`'s macOS and Linux code answers one more method channel call,
  `nativeMarker`, which the Dart API never makes: it keeps the marker strings
  the checks look for reachable. The Swift marker is longer than 15 bytes,
  since Swift keeps shorter literals inline in the machine code. The plugin
  template's Linux unit tests are left out, like the Android ones.
- `melos6/app` is a copy of `path_modules/app` with only `android/`, renamed
  to `melos6_app`; `melos6_local/app` is a copy of it, renamed to
  `melos6_local_app`.
