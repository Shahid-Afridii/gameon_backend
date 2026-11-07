import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { admin } from '../src/config/supabase.js';
import { env } from '../src/config/environment.js';
import { emailFor, passwordFor } from '../src/modules/auth/test-login.service.js';

if (!env.GAMEON_TEST_LOGIN_ENABLED || env.NODE_ENV === 'production') {
  throw new Error('Seed logins require GAMEON_TEST_LOGIN_ENABLED=true in a non-production backend.');
}
// Read before changing remote accounts; never print the file or its secrets.
const envPath = resolve('.env');
const envText = await readFile(envPath, 'utf8');
const accounts = [];
for (let page = 1; page <= 50; page++) {
  const result = await admin.auth.admin.listUsers({ page, perPage: 200 });
  if (result.error) throw new Error('Could not read test accounts. Check the backend service-role configuration.');
  for (const user of result.data.users) {
    if (user.user_metadata?.gameon_seed !== 'nurtur-testing-v1') continue;
    const key = user.user_metadata.gameon_seed_key || (user.email?.endsWith('@seed.gameon.invalid') ? user.email.split('@')[0] : null);
    if (!key || createHash('md5').update(`gameon-testing-v1:${key}`).digest('hex') !== user.id.replaceAll('-', '')) {
      throw new Error('Seed identity marker does not match its deterministic ID. No unrelated accounts will be changed.');
    }
    accounts.push({ user, key });
  }
  if (result.data.users.length < 200) break;
  if (page === 50) throw new Error('User directory exceeds the test-seed scan limit.');
}
if (!accounts.length) {
  const fixtures = await admin.from('gameon_teams').select('id').in('name', ['Kovai Falcons (Test)', 'Coimbatore Titans (Test)']);
  if (!fixtures.error && fixtures.data?.length) {
    throw new Error('Seeded teams exist, but Auth cannot see the SQL-created accounts. Run supabase/seeds/repair_fixture_auth.sql, then rerun this command. Do not reseed the teams.');
  }
  throw new Error('No fixture accounts found in this backend project. Run nurtur_knights_testing.sql in the matching Supabase project first.');
}
const successful = [];
let failures = 0;
for (const { user, key } of accounts) {
  const result = await admin.from('gameon_profiles').select('phone,name').eq('id', user.id).single();
  if (result.error || !/^[6-9]\d{9}$/.test(result.data?.phone || '')) {
    failures++; console.error(`Skipping ${key}: no valid fixture phone.`); continue;
  }
  const phone = result.data.phone;
  const updated = await admin.auth.admin.updateUserById(user.id, {
    email: emailFor(phone), password: await passwordFor(phone), email_confirm: true,
    user_metadata: { ...user.user_metadata, gameon_seed_key: key },
  });
  if (updated.error) {
    failures++; console.error(`Could not enable ${key}. Check for a conflicting test email.`); continue;
  }
  successful.push(phone);
  console.info(`${result.data.name}: ${phone}`);
}
// Keep all existing allowed test accounts, add only successfully configured fixtures.
const allowed = [...new Set([...env.testPhones, ...successful])];
const line = `GAMEON_TEST_PHONES=${allowed.join(',')}`;
const next = /^\s*(?:export\s+)?GAMEON_TEST_PHONES\s*=/m.test(envText)
  ? envText.replace(/^[ \t]*(?:export[ \t]+)?GAMEON_TEST_PHONES[ \t]*=.*$/m, () => line)
  : `${envText.endsWith('\n') ? envText : `${envText}\n`}${line}\n`;
await writeFile(envPath, next, { mode: 0o600 });
console.info(`Enabled ${successful.length} fixture logins. Existing static codes and accounts are unchanged.`);
console.info('Restart the backend. Seeded players/captains use GAMEON_TEST_USER_CODE; existing admins use GAMEON_TEST_ADMIN_CODE.');
if (failures) process.exitCode = 1;
