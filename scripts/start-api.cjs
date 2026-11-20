const fs = require('node:fs');
const path = require('node:path');
const { parseEnv } = require('node:util');

const envPath = path.resolve(__dirname, '..', '.env');
if (process.argv.includes('--local')) {
  const localPath = `${envPath}.local`;
  if (!fs.existsSync(localPath)) {
    console.error('Create backend/.env.local from .env.example and fill in your Supabase credentials.');
    process.exit(1);
  }
  const templatePath = `${envPath}.example`;
  const defaults = fs.existsSync(templatePath) ? parseEnv(fs.readFileSync(templatePath, 'utf8')) : {};
  const local = parseEnv(fs.readFileSync(localPath, 'utf8'));
  const credentials = [local.PUBLIC_SUPABASE_PUBLISHABLE_KEY, local.SUPABASE_SERVICE_ROLE_KEY];
  if (!URL.parse(local.PUBLIC_SUPABASE_URL || '') ||
      credentials.some((key) => !key || key.startsWith('YOUR_'))) {
    console.error('Set a valid Supabase URL and both Supabase keys in backend/.env.local.');
    process.exit(1);
  }
  Object.assign(process.env, defaults, local, {
    NODE_ENV: 'development',
    PORT: '4001',
    TRUST_PROXY_HOPS: '0',
  });
} else if (fs.existsSync(envPath)) {
  for (const raw of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const separator = line.indexOf('=');
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    )
      value = value.slice(1, -1);
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

import('../src/server.js').catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
