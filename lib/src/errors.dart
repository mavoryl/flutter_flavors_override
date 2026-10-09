/// A problem with the user's project or declarations; the CLI prints [message]
/// and exits with code 1.
class FlavorOverridesException implements Exception {
  FlavorOverridesException(this.message);

  final String message;

  @override
  String toString() => message;
}
