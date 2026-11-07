import test from 'node:test';
import assert from 'node:assert/strict';
import { schemas } from '../src/routes/schemas.js';
const teamId = 'b2bd2c31-b538-467d-87e7-d94fd815cb79';
test('poll API validates creation, votes and rejects actor spoofing', () => {
 const parse = (v) => schemas.teamPoll.safeParse(v).success;
 assert.equal(parse({operation:'list', teamId}), true);
 assert.equal(parse({operation:'create', teamId}), false);
 assert.equal(parse({operation:'create', teamId, title:'Weekend XI', matchDate:'2026-11-08'}), true);
 assert.equal(parse({operation:'vote', teamId, pollId:teamId, answer:'maybe'}), false);
 assert.equal(parse({operation:'vote', teamId, pollId:teamId, answer:'yes'}), true);
 assert.equal(parse({operation:'vote', teamId, pollId:teamId, answer:'no', actor:teamId}), false);
});
process.env.PUBLIC_SUPABASE_URL = 'https://example.supabase.co';
process.env.PUBLIC_SUPABASE_PUBLISHABLE_KEY = 'test-public-key';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'test-server-key-not-real-123456';
process.env.NODE_ENV = 'test';
test('poll service passes authenticated identity and surfaces closed-poll rejection', async () => {
 const { admin } = await import('../src/config/supabase.js');
 const { teamPoll } = await import('../src/modules/teams/team-polls.service.js');
 const original = admin.rpc;
 try {
  admin.rpc = async (name, args) => {
   assert.equal(name, 'gameon_team_poll_action');
   assert.equal(args.actor, teamId);
   return {data:null, error:{code:'P0001', message:'This poll has closed.'}};
  };
  await assert.rejects(() => teamPoll({user:{id:teamId},body:{operation:'vote',teamId,pollId:teamId,answer:'yes'}}), /This poll has closed/);
 } finally { admin.rpc = original; }
});
test('creating a poll notifies squad members once, excluding creator; reads and votes send no push', async () => {
 const { admin } = await import('../src/config/supabase.js');
 const { teamPoll } = await import('../src/modules/teams/team-polls.service.js');
 const originalRpc = admin.rpc, originalFrom = admin.from;
 const recipients = [];
 const member = '91c7c1db-a361-4b1a-a12e-bd713b90a034';
 try {
  admin.rpc = async () => ({data:[{responses:[{id:teamId},{id:member},{id:member}]}],error:null});
  admin.from = (table) => {
   if (table === 'gameon_team_poll_votes') return {select: () => ({in: async () => ({data:[],error:null})})};
   if (table === 'gameon_profiles') return {select: () => ({in: async () => ({data:[{id:member,jersey_number:7}],error:null})})};
   assert.equal(table, 'gameon_push_tokens');
   return {select: () => ({in: async (column, ids) => {recipients.push(ids); return {data:[],error:null};}})};
  };
  await teamPoll({user:{id:teamId},body:{operation:'create', teamId, title:'Weekend match?', matchDate:'2026-11-08'}});
  assert.deepEqual(recipients, [[member]]);
  await teamPoll({user:{id:teamId},body:{operation:'list',teamId}});
  await teamPoll({user:{id:teamId},body:{operation:'vote',teamId,pollId:teamId,answer:'yes'}});
  assert.equal(recipients.length,1);
 } finally {admin.rpc = originalRpc; admin.from = originalFrom;}
});
