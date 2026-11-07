import test from 'node:test';
import assert from 'node:assert/strict';
process.env.PUBLIC_SUPABASE_URL = 'https://example.supabase.co';
process.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY = 'test-public-key';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'test-server-key-not-real-123456';
process.env.NODE_ENV = 'test';
process.env.GAMEON_TEST_LOGIN_ENABLED = 'false';
const { parseEnvironment } = await import('../src/config/environment.js');
const { schemas } = await import('../src/routes/schemas.js');
const { phoneValue } = await import('../src/lib/validation.js');
const { authenticate } = await import('../src/middleware/authenticate.js');
const { admin } = await import('../src/config/supabase.js');
const { login } = await import('../src/modules/auth/test-login.service.js');
const { createCommunity } = await import('../src/modules/communities/create-community.service.js');
const { saveTeam } = await import('../src/modules/teams/save-team.service.js');
const { check } = await import('../src/lib/errors.js');

test('production refuses static authentication even with valid test settings', () => {
  assert.throws(() =>
    parseEnvironment({
      ...process.env,
      NODE_ENV: 'production',
      GAMEON_TEST_LOGIN_ENABLED: 'true',
      GAMEON_AUTH_SECRET: 'a'.repeat(32),
      GAMEON_TEST_PHONES: '9000000000',
      GAMEON_TEST_USER_CODE: '9636',
      GAMEON_TEST_ADMIN_CODE: '5671',
    }),
  );
});
test('disabled test login refuses before touching database', async () => {
  await assert.rejects(
    login({ phone: '9000000000', name: 'Tester', code: '9636' }, {}),
    /disabled/,
  );
});
test('schemas reject privilege injection, coerced booleans and malformed IDs', () => {
  assert.equal(
    schemas.saveProfile.safeParse({ values: { name: 'Tester', role: 'superadmin' } }).success,
    false,
  );
  assert.equal(
    schemas.saveProfile.safeParse({
      values: { name: 'Tester', role: 'Captain', phone: '9000000000' },
    }).success,
    false,
  );
  assert.equal(
    schemas.saveTeam.safeParse({ values: { name: 'Team', hasGround: 'false' } }).success,
    false,
  );
  assert.equal(
    schemas.reviewRequest.safeParse({ requestId: 'not-a-uuid', decision: 'approved' }).success,
    false,
  );
  assert.equal(
    schemas.requestJoin.safeParse({
      communityId: 'b2bd2c31-b538-467d-87e7-d94fd815cb79',
      accepted: false,
    }).success,
    false,
  );
});
test('valid captain profile remains compatible with current payload', () => {
  assert.equal(
    schemas.saveProfile.safeParse({
      values: { name: 'Shahid', role: 'Captain', email: '', teamName: 'GameOn XI' },
    }).success,
    true,
  );
});
test('Indian numbers normalize without accepting arbitrary phone text', () => {
  assert.equal(phoneValue('+91 90000 00000'), '9000000000');
  assert.throws(() => phoneValue('1234567890'));
});
test('missing bearer token cannot create a user context', async () => {
  let nextCalled = false;
  await assert.rejects(
    authenticate({ get: () => undefined }, {}, () => {
      nextCalled = true;
    }),
    /Sign in/,
  );
  assert.equal(nextCalled, false);
});
test('a rejected auth token never reaches protected handlers', async () => {
  const original = admin.auth.getUser;
  admin.auth.getUser = async () => ({ data: { user: null }, error: new Error('invalid') });
  try {
    await assert.rejects(
      authenticate({ get: () => 'Bearer invalid' }, {}, () => assert.fail()),
      /expired/,
    );
  } finally {
    admin.auth.getUser = original;
  }
});
test('non-admin cannot create a community with the service role', async () => {
  const original = admin.from;
  admin.from = (table) => {
    assert.equal(table, 'gameon_admins');
    return {
      select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: null }) }) }),
    };
  };
  try {
    await assert.rejects(
      createCommunity({ body: {}, user: { id: 'player-id' }, client: {} }),
      /Superadmin/,
    );
  } finally {
    admin.from = original;
  }
});
test('player cannot save a captain team', async () => {
  const original = admin.from;
  admin.from = () => ({
    select: () => ({
      eq: () => ({
        single: async () => ({ data: { role: 'Player', completed: true }, error: null }),
      }),
    }),
  });
  try {
    await assert.rejects(
      saveTeam({ body: { values: { name: 'Team' } }, user: { id: 'player-id' }, client: {} }),
      /captain profile/,
    );
  } finally {
    admin.from = original;
  }
});
test('database internals are not returned to clients', () => {
  assert.throws(
    () => check({ error: { code: 'XX000', message: 'secret SQL detail' } }),
    (error) => !error.message.includes('secret'),
  );
});

test('cricket specialties are separate from account permissions and accept only supported roles', () => {
  for (const cricketRole of ['Batsman', 'Bowler', 'All-rounder', 'Wicketkeeper-batsman']) {
    const result = schemas.saveProfile.safeParse({values:{name:'Shahid',role:'Captain',cricketRole}});
    assert.equal(result.success,true);
    assert.equal(result.data.values.role,'Captain');
    assert.equal(result.data.values.cricketRole,cricketRole);
  }
  assert.equal(schemas.saveProfile.safeParse({values:{name:'Shahid',role:'Player',cricketRole:'admin'}}).success,false);
  assert.equal(schemas.saveProfile.safeParse({values:{name:'Shahid',role:'Batsman'}}).success,false);
});

test('jersey numbers support zero and reject invalid or injected values', () => {
  const values = { name: 'Shahid', role: 'Player', cricketRole: 'Batsman' };
  for (const jerseyNumber of [0, 7, 99, null]) assert.equal(schemas.saveProfile.safeParse({values:{...values,jerseyNumber}}).success,true);
  for (const jerseyNumber of [-1, 100, 7.5, '7']) assert.equal(schemas.saveProfile.safeParse({values:{...values,jerseyNumber}}).success,false);
});

test('ball preferences accept multiple supported types and reject duplicates or unknown types', () => {
  const values={name:'Shahid',role:'Player'};
  for(const ballTypes of [[],['Stitch ball','Tennis ball'],['Stitch ball','Tennis ball','Cork ball','Soft tennis ball']]) assert.equal(schemas.saveProfile.safeParse({values:{...values,ballTypes}}).success,true);
  for(const ballTypes of [['Tennis ball','Tennis ball'],['invalid'],'Tennis ball']) assert.equal(schemas.saveProfile.safeParse({values:{...values,ballTypes}}).success,false);
});
