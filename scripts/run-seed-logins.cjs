const { existsSync, readdirSync } = require('node:fs');
const { homedir } = require('node:os');
const { resolve, join } = require('node:path');
const { spawnSync } = require('node:child_process');
const usable = (version) => {
  const [major, minor] = version.replace(/^v/, '').split('.').map(Number);
  return major > 22 || (major === 22 && minor >= 13);
};
let binary = usable(process.version) ? process.execPath : null;
if (!binary) {
  const directory = join(process.env.NVM_DIR || join(homedir(), '.nvm'), 'versions', 'node');
  if (existsSync(directory)) {
    const candidates = readdirSync(directory).filter(usable).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    binary = candidates.map((version) => join(directory, version, 'bin', 'node')).find(existsSync);
  }
}
if (!binary) {
  console.error('GameOn requires Node 22.13+. Run: nvm install 22 && nvm use 22');
  process.exit(1);
}
const target = resolve(__dirname, 'enable-seed-logins.js');
const args = process.argv.includes('--check') ? ['--check', target] : ['--env-file-if-exists=.env', target];
const result = spawnSync(binary, args, { cwd: resolve(__dirname, '..'), stdio: 'inherit' });
if (result.error) console.error('Could not start the seed helper with Node 22+.');
process.exit(result.status ?? 1);
