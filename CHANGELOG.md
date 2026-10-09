## 1.0.0

- Initial release.
- Per-flavor `flavor_overrides` declarations in any local pubspec; values are any pub
  dependency spec, relative paths are rebased for the file being written.
- Generates `pubspec_overrides.yaml`: one at a pub workspace root, or one per local package
  that resolves on its own (`path:` modules and melos 6 packages without a workspace).
- Merges into existing files: owns only the entries listed in its marker comment, keeps
  foreign entries (e.g. melos's) and comments, and fails on a conflicting foreign entry.
- `--clean`, `--dry-run`, `--list-dependents`, `-C`.
