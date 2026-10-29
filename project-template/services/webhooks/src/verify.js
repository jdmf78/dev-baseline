import { createHmac, timingSafeEqual } from 'node:crypto';

/** The X-Hub-Signature-256 value GitHub sends for `body`. */
export function sign(secret, body) {
  return `sha256=${createHmac('sha256', secret).update(body).digest('hex')}`;
}

/**
 * Check an X-Hub-Signature-256 header against the raw request bytes.
 * The comparison is constant-time so it can't be probed as a timing oracle.
 */
export function verifySignature(secret, body, header) {
  if (typeof header !== 'string' || !header.startsWith('sha256=')) return false;
  const expected = Buffer.from(sign(secret, body));
  const received = Buffer.from(header);
  return expected.length === received.length && timingSafeEqual(expected, received);
}
