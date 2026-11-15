import { env } from '../../config/environment.js';
import { admin, createPublicClient } from '../../config/supabase.js';
import { check, fail } from '../../lib/errors.js';
import { phoneValue, requireMatchingProfileName } from '../../lib/validation.js';
import { limited } from './login-limits.js';

export async function requestOtp(body, req) {
  const phone = phoneValue(body.phone);
  await limited(phone, req);
  const { error } = await createPublicClient().auth.signInWithOtp({
    phone: `+91${phone}`,
    options: { shouldCreateUser: true, captchaToken: body.captchaToken },
  });
  if (error) fail('Verification message could not be sent. Try again later.', 400);
  return { sent: true };
}
export async function verifyOtp(body, req) {
  const phone = phoneValue(body.phone);
  await limited(phone, req);
  const { data, error } = await createPublicClient().auth.verifyOtp({
    phone: `+91${phone}`,
    token: body.code,
    type: 'sms',
  });
  if (
    error ||
    !data.session ||
    !data.user?.phone_confirmed_at ||
    phoneValue(data.user.phone) !== phone
  )
    fail('Invalid or expired verification code.', 401);
  // Auth identity is authoritative. Never find/link an account by unverified input.
  const inserted = check(
    await admin.from('gameon_profiles').upsert(
      {
        id: data.user.id,
        phone,
        name: body.name,
        role: 'Player',
      },
      { onConflict: 'id', ignoreDuplicates: true },
    ).select('name').maybeSingle(),
  );
  const profile = inserted ?? check(
    await admin.from('gameon_profiles').select('name').eq('id', data.user.id).single(),
  );
  requireMatchingProfileName(profile.name, body.name);
  return { session: data.session };
}
export async function refreshSession(body) {
  const { data, error } = await createPublicClient().auth.refreshSession({
    refresh_token: body.refreshToken,
  });
  if (error && (error.status === 0 || error.status === 429 || error.status >= 500))
    fail('Session verification is temporarily unavailable. Try again.', 503);
  if (error || !data.session) fail('Session expired. Sign in again.', 401);
  return { session: data.session };
}
export async function logout(token) {
  const { error } = await admin.auth.admin.signOut(token, 'global');
  if (error) fail('Could not sign out. Try again.', 503);
  return { signedOut: true };
}
export async function requestPhoneChange({ body, token, user, req }) {
  if (!user.phone_confirmed_at) fail('Real phone authentication is required.', 403);
  const phone = phoneValue(body.phone);
  await limited(phone, req);
  // A bearer-only API has no refresh session in the SDK. Call Auth's user endpoint
  // with the verified caller token, never with the service role (which bypasses OTP).
  const response = await fetch(`${env.PUBLIC_SUPABASE_URL.replace(/\/$/, '')}/auth/v1/user`, {
    method: 'PUT',
    headers: {
      apikey: env.PUBLIC_SUPABASE_PUBLISHABLE_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ phone: `+91${phone}` }),
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) fail('Phone change could not be started.', 400);
  return { sent: true };
}
export async function verifyPhoneChange({ body, client, user, req }) {
  const phone = phoneValue(body.phone);
  await limited(phone, req);
  const { data, error } = await client.auth.verifyOtp({
    phone: `+91${phone}`,
    token: body.code,
    type: 'phone_change',
  });
  if (error || data.user?.id !== user.id || phoneValue(data.user.phone) !== phone)
    fail('Invalid or expired verification code.', 401);
  // The database trigger synchronizes the verified phone atomically with Auth.
  return { session: data.session, changed: true };
}
