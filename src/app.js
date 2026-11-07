import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import { rateLimit } from 'express-rate-limit';
import { randomUUID } from 'node:crypto';
import { env } from './config/environment.js';
import { admin } from './config/supabase.js';
import { fail } from './lib/errors.js';
import { createApiRouter } from './routes/api.routes.js';
export function createApp({ apiRouter = createApiRouter() } = {}) {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', env.TRUST_PROXY_HOPS);
  app.use((req, res, next) => {
    req.id = randomUUID();
    res.set('X-Request-ID', req.id);
    res.set('Cache-Control', 'no-store');
    const started = Date.now();
    res.on('finish', () =>
      console.info(
        JSON.stringify({
          requestId: req.id,
          method: req.method,
          status: res.statusCode,
          durationMs: Date.now() - started,
        }),
      ),
    );
    next();
  });
  app.use(helmet());
  app.use(
    cors({
      origin(origin, done) {
        if (!origin || env.allowedOrigins.includes(origin)) return done(null, true);
        const error = new Error('Browser origin is not allowed.');
        error.status = 403;
        done(error);
      },
      methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
      allowedHeaders: ['Content-Type', 'Authorization'],
      credentials: false,
    }),
  );
  app.get('/health/live', (req, res) => res.json({ status: 'ok' }));
  app.get('/health/ready', async (req, res) => {
    const { error } = await admin.from('gameon_communities').select('id').limit(1);
    if (error) fail('Database is unavailable.', 503);
    res.json({ status: 'ready' });
  });
  app.use(
    '/api',
    rateLimit({
      windowMs: 60000,
      limit: 120,
      standardHeaders: 'draft-8',
      legacyHeaders: false,
      message: { error: 'Too many requests. Try again later.' },
    }),
  );
  app.use('/api', express.json({ limit: '20kb', strict: true }));
  app.use('/api/v1', apiRouter);
  app.use((req, res) => res.status(404).json({ error: 'Route not found.', requestId: req.id }));
  app.use((error, req, res, next) => {
    if (res.headersSent) return next(error);
    const status =
      error.type === 'entity.too.large'
        ? 413
        : error.type === 'entity.parse.failed'
          ? 400
          : error.status || 500;
    if (status >= 500)
      console.error(JSON.stringify({ requestId: req.id, event: 'request_failed', status,
        ...(error.expose ? { reason: error.message } : {}),
      }));
    res.status(status).json({
      error:
        status >= 500 && !error.expose
          ? 'The server could not complete this request.'
          : status === 413
            ? 'Request is too large.'
            : error.type === 'entity.parse.failed'
              ? 'Send valid JSON.'
              : error.message,
      requestId: req.id,
    });
  });
  return app;
}
