## 1.0.0

- Initial release.
- Per-flavor overrides in one `flavor_overrides.yaml` next to the root `pubspec.yaml` (workspace
  root, melos root or app), found from any directory below it: package, then flavor, then any pub
  dependency spec. Relative paths are relative to the file and rebased for every file written (`/`
  separators on every platform, including other Windows drives and UNC shares).
- Applies each override to every local package whose resolution uses the package: a dependency
  of it or of a local package it reaches, or an entry of its `pubspec.lock`. Never to the package
  itself; an override no package uses is left out with a warning.
- Generates `pubspec_overrides.yaml`: one at a pub workspace root, or one per local package that
  resolves on its own (`path:` modules, `path:` overrides and melos 6 packages without a
  workspace).
- Checks before writing anything: a `path:` override must point to a package of that name; pub
  workspace members cannot be overridden (pub refuses), with a hint to depend on the package
  through `path:` instead; a `flavor_overrides.yaml` elsewhere in the project or a
  `flavor_overrides` section in a pubspec is an error.
- Merges into existing files: owns only the entries listed in its marker comment, keeps
  foreign entries and comments, takes over entries melos manages, fails on a conflicting
  hand-written entry, and gives the file back byte for byte (line endings included) when its
  own entries go.
- Carries the pubspec's own `dependency_overrides` over whenever it writes entries.
- Notes an undeclared `--flavor` on stderr with close matches and the declared flavors.
- `--clean` (also without `flavor_overrides.yaml`), `--dry-run`, `--list-dependents`, `-C`.
