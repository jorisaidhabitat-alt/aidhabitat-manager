import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

class LocalPasswordHasher {
  const LocalPasswordHasher._();

  static const int _iterations = 210000;
  static const int _hashBytes = 32;
  static const String _prefix = 'pbkdf2-sha256\$v1';

  static String hash(String password, String salt) {
    final derived = _derive(password, salt, _iterations);
    return '$_prefix\$$_iterations\$${base64UrlEncode(derived)}';
  }

  static bool verify(String password, String salt, String expectedHash) {
    if (expectedHash.startsWith('$_prefix\$')) {
      final parts = expectedHash.split(r'$');
      if (parts.length != 4 ||
          parts[0] != 'pbkdf2-sha256' ||
          parts[1] != 'v1') {
        return false;
      }
      final iterations = int.tryParse(parts[2]);
      if (iterations == null || iterations < 100000 || iterations > 1000000) {
        return false;
      }
      try {
        final actual = _derive(password, salt, iterations);
        final expected = base64Url.decode(base64Url.normalize(parts[3]));
        return _constantTimeEquals(actual, expected);
      } on FormatException {
        return false;
      }
    }

    final legacyHash = sha256
        .convert(utf8.encode('$salt::$password'))
        .toString();
    return _constantTimeEquals(
      utf8.encode(legacyHash),
      utf8.encode(expectedHash),
    );
  }

  static bool isCurrent(String hash) {
    return hash.startsWith('$_prefix\$$_iterations\$');
  }

  static Uint8List _derive(String password, String salt, int iterations) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(
        Pbkdf2Parameters(
          Uint8List.fromList(utf8.encode(salt)),
          iterations,
          _hashBytes,
        ),
      );
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }

  static bool _constantTimeEquals(List<int> left, List<int> right) {
    var difference = left.length ^ right.length;
    final length = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < length; index++) {
      final leftByte = index < left.length ? left[index] : 0;
      final rightByte = index < right.length ? right[index] : 0;
      difference |= leftByte ^ rightByte;
    }
    return difference == 0;
  }
}
