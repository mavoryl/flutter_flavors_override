# Example

An app depends on a plugin that `prod` builds must not contain. A no-op stub with the same
package name lives next to the app:

```text
my_app/
  pubspec.yaml
stubs/
  some_plugin/        # name: some_plugin, same Dart API, no `flutter: plugin:` section
    pubspec.yaml
    lib/some_plugin.dart
```

`my_app/pubspec.yaml`:

```yaml
name: my_app
environment:
  sdk: ^3.4.0
dependencies:
  flutter:
    sdk: flutter
  some_plugin: 1.2.0

flavor_overrides:
  prod:
    some_plugin:
      path: ../stubs/some_plugin
```

`stubs/some_plugin/pubspec.yaml`:

```yaml
name: some_plugin
environment:
  sdk: ^3.4.0
dependencies:
  flutter:
    sdk: flutter
# No `flutter: plugin:` section: nothing native gets registered or built.
```

Build `prod` without the plugin's native code, then go back to the real plugin:

```console
$ dart pub global activate flutter_flavor_overrides
$ cd my_app
$ flutter_flavor_overrides --flavor prod
wrote pubspec_overrides.yaml (some_plugin)
$ flutter pub get
$ flutter build apk --release --flavor prod

$ flutter_flavor_overrides --flavor dev
removed pubspec_overrides.yaml
$ flutter pub get
```

The generated `pubspec_overrides.yaml` (add it to `.gitignore`):

```yaml
# flutter_flavor_overrides: some_plugin
dependency_overrides:
  some_plugin:
    path: ../stubs/some_plugin
```
