import 'dart:io';

import 'package:flutter_flavor_overrides/flutter_flavor_overrides.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments);
}
