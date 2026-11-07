import { admin } from '../../config/supabase.js';
import { env } from '../../config/environment.js';
import { check, fail } from '../../lib/errors.js';
import { phoneValue } from '../../lib/validation.js';
import { limited } from '../auth/login-limits.js';
import { emailFor, passwordFor, signIn } from '../auth/test-login.service.js';
export async function changePhone({ body, user, req }) {
  if (!env.GAMEON_TEST_LOGIN_ENABLED) fail('Test phone changes are disabled.');
  if (user.phone_confirmed_at) fail('Use verified phone change for real accounts.', 403);
  const phone = phoneValue(body.phone);
  if (!env.testPhones.includes(phone)) fail('Test identity is not allowed.', 403);
  await limited(phone, req);
  if (String(body.code) !== env.GAMEON_TEST_USER_CODE) fail('Incorrect verification code.', 401);
  const current = check(
    await admin.from('gameon_profiles').select('phone').eq('id', user.id).single(),
  );
  if (current.phone === phone) fail('Enter a different mobile number.');
  if (check(await admin.from('gameon_profiles').select('id').eq('phone', phone).maybeSingle()))
    fail('This number is already linked to an account.');
  const password = await passwordFor(phone);
  const result = await admin.auth.admin.updateUserById(user.id, {
    email: emailFor(phone),
    password,
    email_confirm: true,
  });
  if (result.error) fail('Mobile number could not be changed.');
  const updated = await admin.from('gameon_profiles').update({ phone }).eq('id', user.id);
  if (updated.error) {
    await admin.auth.admin.updateUserById(user.id, {
      email: emailFor(current.phone),
      password: await passwordFor(current.phone),
      email_confirm: true,
    });
    fail('Mobile number could not be changed.');
  }
  return { session: await signIn(phone, password) };
}
