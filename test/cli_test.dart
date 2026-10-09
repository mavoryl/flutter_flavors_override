import 'package:flutter_flavor_overrides/flutter_flavor_overrides.dart';
import 'package:test/test.dart';

void main() {
  test('fails without --flavor', () async {
    expect(await run(const []), isNot(0));
  });
}
