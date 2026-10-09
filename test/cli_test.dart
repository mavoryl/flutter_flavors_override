import 'package:flutter_flavors_override/flutter_flavors_override.dart';
import 'package:test/test.dart';

void main() {
  test('fails without --flavor', () async {
    expect(await run(const []), isNot(0));
  });
}
