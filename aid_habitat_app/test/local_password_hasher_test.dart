import 'dart:convert';

import 'package:aid_habitat_app/services/local_password_hasher.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const credentialFixture = 'MotDePasse-Test!42';
  const salt = 'local-test-salt';

  test(
    'PBKDF2 ne conserve pas le mot de passe et vérifie la valeur exacte',
    () {
      final hash = LocalPasswordHasher.hash(credentialFixture, salt);

      expect(hash, startsWith(r'pbkdf2-sha256$v1$210000$'));
      expect(hash, isNot(contains(credentialFixture)));
      expect(LocalPasswordHasher.isCurrent(hash), isTrue);
      expect(LocalPasswordHasher.verify(credentialFixture, salt, hash), isTrue);
      expect(
        LocalPasswordHasher.verify('$credentialFixture-x', salt, hash),
        isFalse,
      );
    },
  );

  test('les anciens hashes SHA-256 restent valides pendant la migration', () {
    final legacy = sha256
        .convert(utf8.encode('$salt::$credentialFixture'))
        .toString();

    expect(LocalPasswordHasher.isCurrent(legacy), isFalse);
    expect(LocalPasswordHasher.verify(credentialFixture, salt, legacy), isTrue);
    expect(
      LocalPasswordHasher.verify('$credentialFixture-x', salt, legacy),
      isFalse,
    );
  });

  test('un hash PBKDF2 mal formé est refusé', () {
    expect(
      LocalPasswordHasher.verify(
        credentialFixture,
        salt,
        r'pbkdf2-sha256$v1$210000$invalide***',
      ),
      isFalse,
    );
  });
}
