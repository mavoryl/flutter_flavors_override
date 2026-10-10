import 'package:path/path.dart' as p;

/// [path] relative to [from], with `/` separators; `.` for [from] itself.
///
/// When no relative path exists (another drive or UNC share on Windows), the
/// absolute path is returned, also with `/`: Windows accepts both separators,
/// and `\` cannot be part of a Windows file name. On POSIX `\` is an ordinary
/// file name character and stays.
String portableRelative(String path,
    {required String from, p.Context? context}) {
  final ctx = context ?? p.context;
  final relative = ctx.relative(path, from: from);
  return ctx.style == p.Style.windows
      ? relative.replaceAll(r'\', '/')
      : relative;
}

/// Rebases a relative [path] written in a pubspec in [fromDir] so that it
/// points to the same place from [toDir].
String rebasePath(
  String path, {
  required String fromDir,
  required String toDir,
  p.Context? context,
}) {
  final ctx = context ?? p.context;
  final target = ctx.normalize(ctx.join(fromDir, path));
  return portableRelative(target, from: toDir, context: ctx);
}
