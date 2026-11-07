import { z } from 'zod/v4';
const boolean = z
  .enum(['true', 'false'])
  .default('false')
  .transform((v) => v === 'true');
export function parseEnvironment(input) {
  const config = z
    .object({
      EXPO_ACCESS_TOKEN: z.string().default(''),
      NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
      PORT: z.coerce.number().int().min(1).max(65535).default(4000),
      PUBLIC_SUPABASE_URL: z.url().refine((v) => v.startsWith('https://')),
      PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(10),
      SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
      CORS_ORIGINS: z.string().default(''),
      TRUST_PROXY_HOPS: z.coerce.number().int().min(0).max(1).default(0),
      GAMEON_TEST_LOGIN_ENABLED: boolean,
      GAMEON_TEST_PHONES: z.string().default(''),
      GAMEON_AUTH_SECRET: z.string().default(''),
      GAMEON_TEST_USER_CODE: z.string().default(''),
      GAMEON_TEST_ADMIN_CODE: z.string().default(''),
    })
    .parse(input);
  if (
    config.GAMEON_TEST_LOGIN_ENABLED &&
    (config.NODE_ENV === 'production' ||
      config.GAMEON_AUTH_SECRET.length < 32 ||
      !/^[0-9]{4,8}$/.test(config.GAMEON_TEST_USER_CODE) ||
      !/^[0-9]{4,8}$/.test(config.GAMEON_TEST_ADMIN_CODE) ||
      !config.GAMEON_TEST_PHONES)
  ) {
    throw new Error(
      'Test login requires non-production mode, a 32+ character secret, codes and allowed test phones.',
    );
  }
  config.allowedOrigins = config.CORS_ORIGINS.split(',')
    .map((v) => v.trim())
    .filter(Boolean);
  for (const origin of config.allowedOrigins) {
    if (new URL(origin).origin !== origin)
      throw new Error('Use exact CORS origins without paths or wildcards.');
  }
  config.testPhones = config.GAMEON_TEST_PHONES.split(',')
    .map((v) => v.trim())
    .filter(Boolean);
  return Object.freeze(config);
}
export const env = parseEnvironment(process.env);
