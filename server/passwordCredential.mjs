import crypto from 'node:crypto';

const PASSWORD_CREDENTIAL_PREFIX = 'scrypt$v1';
const PASSWORD_HASH_BYTES = 64;

export const hashPasswordWithSalt = (password, salt) =>
  crypto.scryptSync(String(password), String(salt), PASSWORD_HASH_BYTES).toString('hex');

export const passwordCredentialChecksum = (serialized) =>
  crypto.createHash('sha256').update(String(serialized)).digest('hex');

export const buildPasswordCredential = (password) => {
  const salt = crypto.randomBytes(16).toString('base64url');
  const hash = hashPasswordWithSalt(password, salt);
  const serialized = `${PASSWORD_CREDENTIAL_PREFIX}$${salt}$${hash}`;
  return {
    serialized,
    salt,
    hash,
    checksum: passwordCredentialChecksum(serialized),
  };
};

export const parsePasswordCredential = (value) => {
  const serialized = String(value || '').trim();
  const parts = serialized.split('$');
  if (
    parts.length !== 4
    || `${parts[0]}$${parts[1]}` !== PASSWORD_CREDENTIAL_PREFIX
    || !/^[A-Za-z0-9_-]{16,}$/.test(parts[2])
    || !/^[a-f0-9]{128}$/i.test(parts[3])
  ) {
    return null;
  }
  return {
    serialized,
    salt: parts[2],
    hash: parts[3].toLowerCase(),
    checksum: passwordCredentialChecksum(serialized),
  };
};

export const verifyPasswordHash = (password, salt, expectedHash) => {
  const expected = Buffer.from(String(expectedHash || ''), 'hex');
  const actual = Buffer.from(hashPasswordWithSalt(password, salt), 'hex');
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
};
