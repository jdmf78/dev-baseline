// GitHub webhook endpoint: verify the signature, drop duplicates, reply fast,
// then run the event's handler after the response has gone out.
import { verifySignature } from './verify.js';

const DEFAULT_MAX_BODY = 5 * 1024 * 1024; // GitHub caps payloads at 25 MB; most are a few KB
const DEFAULT_DEDUPE_TTL = 24 * 60 * 60 * 1000;

/**
 * @param {object} opts
 * @param {string} opts.secret shared secret set on the GitHub webhook
 * @param {Record<string, (ctx: {event: string, delivery: string, payload: any, log: any}) => unknown>} opts.handlers
 * @param {{info: Function, error: Function}} opts.log
 * @param {number} [opts.maxBodyBytes]
 * @param {number} [opts.dedupeTtlMs]
 */
export function createApp({
  secret,
  handlers,
  log,
  maxBodyBytes = DEFAULT_MAX_BODY,
  dedupeTtlMs = DEFAULT_DEDUPE_TTL,
}) {
  if (!secret) throw new Error('webhook secret is required');

  // Delivery GUID -> expiry. In memory is fine for one instance; move this to
  // Redis or your database once you run more than one.
  const seen = new Map();
  const inFlight = new Set();

  function claim(delivery) {
    const now = Date.now();
    for (const [id, expires] of seen) {
      if (expires > now) break; // insertion order = expiry order
      seen.delete(id);
    }
    if (seen.has(delivery)) return false;
    seen.set(delivery, now + dedupeTtlMs);
    return true;
  }

  async function handle(req, res) {
    const path = new URL(req.url ?? '/', 'http://localhost').pathname;
    if (path === '/healthz') return reply(res, 200, { ok: true });
    if (path !== '/webhook') return reply(res, 404, { error: 'not found' });
    if (req.method !== 'POST') return reply(res, 405, { error: 'method not allowed' });

    if (Number(req.headers['content-length'] ?? 0) > maxBodyBytes) {
      return reply(res, 413, { error: 'payload too large' }, true);
    }
    let body;
    try {
      body = await readBody(req, maxBodyBytes);
    } catch (err) {
      return reply(res, err.status ?? 400, { error: err.message }, true);
    }

    // Authenticate the raw bytes before parsing or trusting any header.
    if (!verifySignature(secret, body, req.headers['x-hub-signature-256'])) {
      log.info('rejected: bad signature', { delivery: header(req, 'x-github-delivery') });
      return reply(res, 401, { error: 'invalid signature' });
    }

    const event = header(req, 'x-github-event');
    const delivery = header(req, 'x-github-delivery');
    if (!event || !delivery) return reply(res, 400, { error: 'missing X-GitHub-Event or X-GitHub-Delivery' });

    let payload;
    try {
      payload = JSON.parse(body.toString('utf8'));
    } catch {
      return reply(res, 400, { error: 'body is not JSON: set the webhook content type to application/json' });
    }

    const handler = Object.hasOwn(handlers, event) ? handlers[event] : undefined;
    if (!handler) return reply(res, 202, { ignored: event });
    if (!claim(delivery)) return reply(res, 200, { duplicate: delivery });

    // GitHub waits at most 10 s for a response, so acknowledge before working.
    reply(res, 202, { accepted: delivery });
    const job = (async () => {
      try {
        await handler({ event, delivery, payload, log });
        log.info('processed', { event, delivery });
      } catch (err) {
        seen.delete(delivery); // a redelivery reuses the GUID; let it run again
        log.error('handler failed', { event, delivery, error: String(err?.stack ?? err) });
      }
    })();
    inFlight.add(job);
    job.finally(() => inFlight.delete(job));
  }

  return {
    handle,
    /** Resolves once every accepted delivery has finished processing. */
    drain: () => Promise.allSettled([...inFlight]),
  };
}

function header(req, name) {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function reply(res, status, body, close = false) {
  const headers = { 'content-type': 'application/json' };
  if (close) headers.connection = 'close';
  res.writeHead(status, headers);
  res.end(JSON.stringify(body));
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    const onData = (chunk) => {
      size += chunk.length;
      if (size > limit) {
        req.off('data', onData);
        reject(Object.assign(new Error('payload too large'), { status: 413 }));
        return;
      }
      chunks.push(chunk);
    };
    req.on('data', onData);
    req.once('end', () => resolve(Buffer.concat(chunks)));
    req.once('error', reject);
  });
}
