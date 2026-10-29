import { test } from 'node:test';
import assert from 'node:assert/strict';
import { sign, verifySignature } from '../src/verify.js';

// Example values from GitHub's "Validating webhook deliveries" docs.
const SECRET = "It's a Secret to Everybody";
const BODY = Buffer.from('Hello, World!');
const SIGNATURE = 'sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17';

test('sign matches the example GitHub publishes', () => {
  assert.equal(sign(SECRET, BODY), SIGNATURE);
});

test('accepts a valid signature', () => {
  assert.equal(verifySignature(SECRET, BODY, SIGNATURE), true);
});

test('rejects the wrong secret', () => {
  assert.equal(verifySignature('not the secret', BODY, SIGNATURE), false);
});

test('rejects a modified body', () => {
  assert.equal(verifySignature(SECRET, Buffer.from('Hello, World?'), SIGNATURE), false);
});

test('rejects missing or malformed headers', () => {
  for (const header of [undefined, '', 'sha1=abc', 'sha256=', SIGNATURE.slice(0, -1), [SIGNATURE]]) {
    assert.equal(verifySignature(SECRET, BODY, header), false, `header: ${header}`);
  }
});
