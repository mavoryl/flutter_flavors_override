/// The note for a `--flavor` that no pubspec in the project declares: most
/// likely a typo. Suggests close [declared] flavors and lists all of them.
String missingFlavorNote(String flavor, Iterable<String> declared) {
  final head = 'no flavor_overrides for flavor `$flavor` in this project';
  final flavors = declared.toSet().toList()..sort();
  if (flavors.isEmpty) return '$head: no pubspec declares flavor_overrides.';

  final close = [
    for (final candidate in flavors)
      if (_distance(flavor, candidate) case final d?) (candidate, d),
  ]..sort((a, b) => a.$2 != b.$2 ? a.$2 - b.$2 : a.$1.compareTo(b.$1));
  final suggestion = close.isEmpty
      ? ''
      : ' Did you mean ${close.map((c) => '`${c.$1}`').join(' or ')}?';
  return '$head.$suggestion Declared flavors: ${flavors.join(', ')}.';
}

/// How far [candidate] is from [flavor], or null when it is not close: a
/// letter-case variant, a few edits away, or one name starting the other
/// (`dev` and `develop`).
int? _distance(String flavor, String candidate) {
  final a = flavor.toLowerCase();
  final b = candidate.toLowerCase();
  final edits = _levenshtein(a, b);
  if (edits <= 2) return edits;
  if (a.startsWith(b) || b.startsWith(a)) return edits;
  return null;
}

int _levenshtein(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      final deletion = previous[j] + 1;
      final insertion = current[j - 1] + 1;
      current[j] =
          [substitution, deletion, insertion].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  return previous[b.length];
}
