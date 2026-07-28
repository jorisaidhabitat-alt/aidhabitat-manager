import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildPasswordCredential,
  parsePasswordCredential,
  verifyPasswordHash,
} from '../server/passwordCredential.mjs';

test('serializes a password as a non-reversible scrypt credential', () => {
  const password = 'Test-Password-42!';
  const credential = buildPasswordCredential(password);

  assert.match(credential.serialized, /^scrypt\$v1\$/);
  assert.equal(credential.serialized.includes(password), false);
  assert.equal(credential.hash.length, 128);
  assert.equal(verifyPasswordHash(password, credential.salt, credential.hash), true);
  assert.equal(verifyPasswordHash('wrong-password', credential.salt, credential.hash), false);
});

test('parses a serialized credential without changing its fingerprint', () => {
  const original = buildPasswordCredential('Another-Password-42!');
  const parsed = parsePasswordCredential(original.serialized);

  assert.deepEqual(parsed, original);
});

test('rejects plaintext and malformed credentials', () => {
  assert.equal(parsePasswordCredential('plaintext-password'), null);
  assert.equal(parsePasswordCredential('scrypt$v1$invalid$hash'), null);
  assert.equal(parsePasswordCredential(''), null);
});
