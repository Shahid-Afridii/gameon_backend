import { webcrypto } from 'node:crypto';
import { admin } from '../../config/supabase.js';
import { check, fail } from '../../lib/errors.js';
export async function limited(phone, req) {
  const ip = req.ip || 'unknown';
  const hash = Array.from(
    new Uint8Array(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(ip))),
    (x) => x.toString(16).padStart(2, '0'),
  ).join('');
  for (const [bucket, max_attempts] of [
    [`phone:${phone}`, 10],
    [`ip:${hash}`, 60],
  ]) {
    const allowed = check(
      await admin.rpc('gameon_consume_login_attempt', { bucket, max_attempts }),
    );
    if (!allowed) fail('Too many attempts. Please try again in 10 minutes.', 429);
  }
}
