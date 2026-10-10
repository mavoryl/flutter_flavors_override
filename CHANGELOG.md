## 1.0.0

- Initial release.
- Per-flavor `flavor_overrides` declarations in any local pubspec; values are any pub
  dependency spec, relative paths are rebased for the file being written (`/` separators on
  every platform, including other Windows drives and UNC shares).
- Generates `pubspec_overrides.yaml`: one at a pub workspace root, or one per local package
  that resolves on its own (`path:` modules, `path:` overrides and melos 6 packages without a
  workspace). Finds the workspace or melos root from any package below it.
- Merges into existing files: owns only the entries listed in its marker comment, keeps
  foreign entries and comments, takes over entries melos manages, fails on a conflicting
  hand-written entry, and gives the file back byte for byte (line endings included) when its
  own entries go.
- Carries the pubspec's own `dependency_overrides` over whenever it writes entries.
- Refuses to override pub workspace members (pub cannot), with a hint to depend on the package
  through `path:` instead.
- Notes an undeclared `--flavor` on stderr with close matches and the declared flavors.
- `--clean`, `--dry-run`, `--list-dependents`, `-C`.
