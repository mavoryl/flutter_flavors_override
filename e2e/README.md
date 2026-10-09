# End-to-end fixtures

Real Flutter builds that check the idea behind `flutter_flavor_overrides`: a
`pubspec_overrides.yaml` that swaps a plugin for a no-op stub keeps the
plugin's native code out of a flavor's Android and iOS build, and leaving the
file out brings it back.

None of this is part of the published package (`/e2e/` is in `.pubignore`) or
of the root package's analysis (`analysis_options.yaml` excludes it).

## Layout

```
e2e/
├── plugins/ffo_probe/   test plugin with native code (Android, iOS: podspec and Package.swift)
├── stubs/ffo_probe/     its no-op stub: same name and Dart API, no `flutter: plugin:`
├── single/              one app package that depends on ffo_probe
├── workspace/           pub workspace: app/ -> packages/feature/ -> ffo_probe
├── path_modules/        no workspace: app/ -> path: packages/feature/ -> ffo_probe
└── tool/
    ├── verify.sh            builds a fixture and checks the plugin's footprint
    └── add_ios_flavors.rb   adds the iOS flavor configurations and schemes
```

The package that depends on `ffo_probe` declares the override for `prod`, with
a path relative to its own pubspec:

```yaml
flavor_overrides:
  prod:
    ffo_probe:
      path: ../stubs/ffo_probe
```

`<fixture>/expected/prod/` holds the hand-written `pubspec_overrides.yaml`
files the CLI is expected to generate for `--flavor prod`, laid out as the
fixture itself, with paths relative to where each file goes. With a workspace
there is one file at the workspace root; without one, every local package that
resolves gets its own. `dev` has no overrides, so there is no `expected/dev/`.
Generated overrides files are ignored by git; the ones under `expected/` are
tracked.

## Flavors

Each app has the flavors `dev` and `prod`:

- Android: `productFlavors` with dimension `env` in
  `android/app/build.gradle.kts`; `dev` has the application id suffix `.dev`.
- iOS: build configurations `Debug-<flavor>`, `Release-<flavor>`,
  `Profile-<flavor>` and shared schemes `dev` and `prod`, added by
  `tool/add_ios_flavors.rb` (needs the `xcodeproj` gem, which ships with
  CocoaPods); `dev` has the bundle id suffix `.dev`.

## Running

```bash
e2e/tool/verify.sh <single|workspace|path_modules> <android|ios-cocoapods|ios-spm> <dev|prod>
```

The script never builds in the repository. It copies `e2e/` (the files a fresh
checkout would have) to a temporary directory, removes any
`pubspec_overrides.yaml` there, lays out `expected/<flavor>/`, runs
`flutter pub get` (at the workspace root for `workspace`, in the app and the
feature package for `path_modules`) and builds the app:

- `flutter build apk --release --flavor <flavor>`, or
- `flutter build ios --release --flavor <flavor> --no-codesign`, after setting
  `flutter: config: enable-swift-package-manager:` in the copy of the app's
  pubspec (`false` for `ios-cocoapods`, `true` for `ios-spm`), so the
  machine's global `flutter config` does not matter.

Then it prints one `PASS`/`FAIL` line per check and exits with 0 only if all
passed. In `dev` the plugin must be found, in `prod` it must not:

- `.dart_tool/package_config.json` of every package that resolves points
  `ffo_probe` at the plugin (in `prod`: at the stub);
- `.flutter-plugins-dependencies` lists `ffo_probe`;
- `GeneratedPluginRegistrant` (`.java` or `.m`) registers `FfoProbePlugin`;
- Android: the APK's dex has the class
  `io.github.mavoryl.ffo_probe.FfoProbePlugin` and the plugin's string
  `getPlatformVersion`;
- iOS with CocoaPods: `Podfile.lock` has `ffo_probe`,
  `Runner.app/Frameworks/ffo_probe.framework` exists;
- iOS with Swift Package Manager: the generated
  `FlutterGeneratedPluginSwiftPackage/Package.swift` lists `ffo_probe`;
- iOS: the `Runner` binary mentions `FfoProbePlugin`.

Checks that do not depend on the flavor confirm the setup:

- the flavor was applied: the APK is `app-<flavor>-release.apk` with the
  flavor's application id; the iOS build used the `Release-<flavor>`
  configuration and has the flavor's bundle id;
- the iOS dependency manager is the requested one: with Swift Package Manager
  the generated plugins package depends on `FlutterFramework`, and neither
  `Podfile.lock` nor `Runner.app/Frameworks` has `ffo_probe`; with CocoaPods
  the package depends on neither `FlutterFramework` nor `ffo_probe`. Without
  plugins (`prod`) Flutter does not run `pod install` at all.

Options:

- `--keep` keeps the temporary copy and prints its path.
- `--workdir DIR` reuses a kept copy: switch flavors in place, the way a
  developer would locally, e.g. `prod` and then `dev`.
- `--no-overrides` skips laying out `expected/<flavor>/`: a negative control,
  `prod` must then fail.
- `--logs DIR` writes the pub and build logs to `DIR`.

Requirements: `flutter` on `PATH`, `git`, `tar`. Android: an Android SDK
(`$ANDROID_HOME`, `$ANDROID_SDK_ROOT` or `~/Library/Android/sdk`) with
build-tools that have `dexdump` and `aapt2`. iOS: macOS with Xcode and
CocoaPods.

## Fixture notes

- `ffo_probe` ships a consumer ProGuard rule that keeps its classes' names: R8
  renames classes in release builds, and the dex check looks the plugin up by
  name.
- The iOS deployment target is 15.0, and each app commits its `Podfile`
  (otherwise Flutter generates it on demand) to raise the pods' deployment
  target to 15.0 too: Xcode 27 rejects anything lower, while Flutter's
  templates and the `Flutter` pod still say 13.0. The `Podfile` also maps the
  flavor configurations to `:debug` and `:release`.
- The apps were created with `flutter create --platforms=android,ios --org
  io.github.mavoryl`, then `ruby e2e/tool/add_ios_flavors.rb
  <app>/ios/Runner.xcodeproj`.
