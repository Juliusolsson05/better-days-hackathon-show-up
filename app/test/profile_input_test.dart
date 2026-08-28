import 'package:flutter_test/flutter_test.dart';
import 'package:showup/models/profile_input.dart';

void main() {
  test('SF phone input crosses the repository boundary as E.164', () {
    expect(normalizeSfPhone('(415) 555-0123'), '+14155550123');
    expect(normalizeSfPhone('1 415 555 0123'), '+14155550123');
    expect(normalizeSfPhone('+46 70 123 45 67'), '+46701234567');
    expect(normalizeSfPhone('+33 1 23 45 67 89'), '+33123456789');
  });

  test('incomplete phone input is rejected instead of guessed', () {
    expect(normalizeSfPhone('555-0123'), isNull);
    expect(normalizeSfPhone(''), isNull);
  });
}
