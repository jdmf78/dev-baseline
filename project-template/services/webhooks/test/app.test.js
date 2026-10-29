import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { createApp } from '../src/app.js';
import { sign } from '../src/verify.js';

const SECRET = 'test-secret';
const silent = { info() {}, error() {} };

async function start(t, handlers, opts = {}) {
  const app = createApp({ secret: SECRET, handlers, log: silent, ...opts });
  const server = createServer((req, res) => app.handle(req, res));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return { app, url: `http://127.0.0.1:${server.address().port}` };
}

function deliver(url, { event = 'push', delivery = randomUUID(), body = '{}', signature } = {}) {
  return fetch(`${url}/webhook`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-github-event': event,
      'x-github-delivery': delivery,
      'x-hub-signature-256': signature ?? sign(SECRET, body),
    },
    body,
  });
}

test('health check and routing', async (t) => {
  const { url } = await start(t, {});
  assert.equal((await fetch(`${url}/healthz`)).status, 200);
  assert.equal((await fetch(`${url}/nope`)).status, 404);
  assert.equal((await fetch(`${url}/webhook`)).status, 405);
});

test('runs the handler for a correctly signed delivery', async (t) => {
  const calls = [];
  const { app, url } = await start(t, { push: (ctx) => calls.push(ctx) });
  const res = await deliver(url, { body: '{"ref":"refs/heads/main"}', delivery: 'd-1' });
  assert.equal(res.status, 202);
  await app.drain();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].payload.ref, 'refs/heads/main');
  assert.equal(calls[0].delivery, 'd-1');
});

test('rejects a bad signature without running the handler', async (t) => {
  let called = false;
  const { url } = await start(t, { push: () => { called = true; } });
  const res = await deliver(url, { signature: sign('wrong-secret', '{}') });
  assert.equal(res.status, 401);
  assert.equal(called, false);
});

test('processes each delivery GUID once', async (t) => {
  let count = 0;
  const { app, url } = await start(t, { push: () => { count++; } });
  assert.equal((await deliver(url, { delivery: 'same' })).status, 202);
  assert.equal((await deliver(url, { delivery: 'same' })).status, 200);
  await app.drain();
  assert.equal(count, 1);
});

test('lets a redelivery run again after the handler failed', async (t) => {
  let attempts = 0;
  const { app, url } = await start(t, {
    push: () => {
      attempts++;
      if (attempts === 1) throw new Error('downstream unavailable');
    },
  });
  await deliver(url, { delivery: 'retry-me' });
  await app.drain();
  assert.equal((await deliver(url, { delivery: 'retry-me' })).status, 202);
  await app.drain();
  assert.equal(attempts, 2);
});

test('acknowledges events without a handler', async (t) => {
  const { url } = await start(t, {});
  const res = await deliver(url, { event: 'star' });
  assert.equal(res.status, 202);
  assert.deepEqual(await res.json(), { ignored: 'star' });
});

test('does not treat inherited object keys as handlers', async (t) => {
  const { url } = await start(t, {});
  const res = await deliver(url, { event: 'constructor' });
  assert.deepEqual(await res.json(), { ignored: 'constructor' });
});

test('rejects a signed body that is not JSON', async (t) => {
  const { url } = await start(t, { push: () => {} });
  assert.equal((await deliver(url, { body: 'payload=%7B%7D' })).status, 400);
});

test('rejects oversized payloads', async (t) => {
  const { url } = await start(t, { push: () => {} }, { maxBodyBytes: 16 });
  assert.equal((await deliver(url, { body: JSON.stringify({ big: 'x'.repeat(64) }) })).status, 413);
});
