import { createApp } from './app.js';
import { env } from './config/environment.js';
const server = createApp().listen(env.PORT, '0.0.0.0', () =>
  console.info(`GameOn API listening on port ${env.PORT}`),
);
server.requestTimeout = 30000;
server.headersTimeout = 15000;
server.keepAliveTimeout = 5000;
for (const signal of ['SIGTERM', 'SIGINT'])
  process.once(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10000).unref();
  });
