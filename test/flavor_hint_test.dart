import 'package:flutter_flavor_overrides/src/flavor_hint.dart';
import 'package:test/test.dart';

void main() {
  group('missingFlavorNote', () {
    test('suggests a close match and lists the declared flavors', () {
      expect(
        missingFlavorNote('prd', ['prod', 'develop']),
        'no flavor_overrides for flavor `prd` in this project. '
        'Did you mean `prod`? Declared flavors: develop, prod.',
      );
    });

    test('suggests every close match, closest first', () {
      expect(
        missingFlavorNote('dev', ['develop', 'devs', 'prod']),
        'no flavor_overrides for flavor `dev` in this project. '
        'Did you mean `devs` or `develop`? '
        'Declared flavors: develop, devs, prod.',
      );
    });

    test('a different letter case is a close match', () {
      expect(
        missingFlavorNote('PROD', ['prod']),
        'no flavor_overrides for flavor `PROD` in this project. '
        'Did you mean `prod`? Declared flavors: prod.',
      );
    });

    test('without a close match only lists the declared flavors', () {
      expect(
        missingFlavorNote('staging', ['prod', 'develop']),
        'no flavor_overrides for flavor `staging` in this project. '
        'Declared flavors: develop, prod.',
      );
    });

    test('says so when the project declares no flavors at all', () {
      expect(
        missingFlavorNote('prod', const []),
        'no flavor_overrides for flavor `prod` in this project: '
        'no pubspec declares flavor_overrides.',
      );
    });

    test('lists a flavor declared in several packages once', () {
      expect(
        missingFlavorNote('qa', ['prod', 'prod']),
        'no flavor_overrides for flavor `qa` in this project. '
        'Declared flavors: prod.',
      );
    });
  });
}
