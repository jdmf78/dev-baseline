// Entry point: config from the environment, JSON logs, graceful shutdown.
import { createServer } from 'node:http';
import { createApp } from './app.js';
import { handlers } from './handlers.js';

const line = (level, msg, fields) => JSON.stringify({ level, time: new Date().toISOString(), msg, ...fields });
const log = {
  info: (msg, fields = {}) => console.log(line('info', msg, fields)),
  error: (msg, fields = {}) => console.error(line('error', msg, fields)),
};

const secret = process.env.WEBHOOK_SECRET;
if (!secret) {
  log.error('WEBHOOK_SECRET is not set (see .env.example)');
  process.exit(1);
}

// Loopback by default; the container sets HOST=0.0.0.0 behind the proxy.
const host = process.env.HOST ?? '127.0.0.1';
const port = Number(process.env.PORT ?? 3000);
const app = createApp({ secret, handlers, log });

const server = createServer((req, res) => {
  app.handle(req, res).catch((err) => {
    log.error('request failed', { error: String(err?.stack ?? err) });
    if (!res.headersSent) res.writeHead(500).end();
  });
});
server.headersTimeout = 10_000;
server.requestTimeout = 30_000;
server.listen(port, host, () => log.info('listening', { host, port }));

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, () => {
    log.info('shutting down', { signal });
    setTimeout(() => process.exit(1), 10_000).unref();
    server.close(async () => {
      await app.drain();
      process.exit(0);
    });
  });
}
