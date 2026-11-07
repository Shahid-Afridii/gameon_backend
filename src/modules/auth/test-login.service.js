import { webcrypto } from 'node:crypto';
import { env } from '../../config/environment.js';
import { admin, createPublicClient } from '../../config/supabase.js';
import { check, fail } from '../../lib/errors.js';
import { phoneValue, text } from '../../lib/validation.js';
import { limited } from './login-limits.js';
export const emailFor = (phone) => `${phone}@phone.gameon.invalid`;
export async function passwordFor(phone) {
  const secret = env.GAMEON_AUTH_SECRET;
  if (!secret || secret.length < 32)
    fail('Set GAMEON_AUTH_SECRET on the backend (at least 32 characters).', 503);
  const key = await webcrypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const bytes = new Uint8Array(
    await webcrypto.subtle.sign('HMAC', key, new TextEncoder().encode(phone)),
  );
  return Array.from(bytes, (x) => x.toString(16).padStart(2, '0')).join('') + 'aA1!';
}
export async function signIn(phone, password, testUserId) {
  const client = createPublicClient();
  let result = await client.auth.signInWithPassword({ email: emailFor(phone), password });
  // An authorized dummy account can migrate after the local test secret changes.
  if (result.error?.code === 'invalid_credentials' && testUserId &&
      env.GAMEON_TEST_LOGIN_ENABLED && env.NODE_ENV !== 'production' && env.testPhones.includes(phone)) {
    const existing = await admin.auth.admin.getUserById(testUserId);
    const user = existing.data?.user;
    if (!existing.error && user?.email === emailFor(phone) && !user.phone_confirmed_at) {
      const updated = await admin.auth.admin.updateUserById(testUserId, { password });
      if (updated.error) fail('Test account credentials could not be synchronized.', 503);
      result = await client.auth.signInWithPassword({ email: emailFor(phone), password });
    }
  }
  if (result.error || !result.data.session) fail('Sign-in could not be completed. Try again.', 401);
  return result.data.session;
}
export async function login(body, req) {
  if (!env.GAMEON_TEST_LOGIN_ENABLED) fail('Test login is disabled.', 503);
  const phone = phoneValue(body.phone),
    name = text(body.name, 2, 60, 'Name');
  if (!env.testPhones.includes(phone)) fail('Test identity is not allowed.', 403);
  await limited(phone, req);
  let profile = check(
    await admin.from('gameon_profiles').select('*').eq('phone', phone).maybeSingle(),
  );
  const admins = check(await admin.from('gameon_admins').select('user_id'));
  const privileged = Boolean(profile && admins.some((a) => a.user_id === profile.id));
  if (String(body.code) !== (privileged ? env.GAMEON_TEST_ADMIN_CODE : env.GAMEON_TEST_USER_CODE))
    fail('Incorrect verification code.', 401);
  const password = await passwordFor(phone);
  if (!profile) {
    const created = await admin.auth.admin.createUser({
      email: emailFor(phone),
      password,
      email_confirm: true,
    });
    if (created.error || !created.data.user) {
      // A concurrent first login may have finished creating the same profile.
      profile = check(
        await admin.from('gameon_profiles').select('*').eq('phone', phone).maybeSingle(),
      );
      if (!profile) fail('Account setup could not be completed. Try again.', 409);
    } else {
      const inserted = await admin
        .from('gameon_profiles')
        .insert({ id: created.data.user.id, phone, name, role: 'Player' })
        .select()
        .single();
      if (inserted.error) {
        await admin.auth.admin.deleteUser(created.data.user.id);
        fail('Profile setup failed. Please run the database migrations.', 503);
      }
      profile = inserted.data;
    }
  }
  check(await admin.from('gameon_profiles').update({ name }).eq('id', profile.id));
  return { session: await signIn(phone, password, profile.id) };
}
