import { createClient } from '@supabase/supabase-js';
import { env } from './environment.js';
const options = {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  global: {
    fetch: (url, options) =>
      fetch(url, { ...options, signal: options?.signal || AbortSignal.timeout(15000) }),
  },
};
// Service role is used only where explicit server-side authorization is required.
export const admin = createClient(env.PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, options);
export const createPublicClient = () =>
  createClient(env.PUBLIC_SUPABASE_URL, env.PUBLIC_SUPABASE_PUBLISHABLE_KEY, options);
export const createUserClient = (token) =>
  createClient(env.PUBLIC_SUPABASE_URL, env.PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    ...options,
    global: { ...options.global, headers: { Authorization: `Bearer ${token}` } },
  });
