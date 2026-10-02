// Vercel serverless function: lets a tenant OWNER create, reset or remove branch logins
// (manager / staff accounts). Needs the service_role key, which lives ONLY here as a Vercel
// environment variable. It is never sent to the browser.
//
// Vercel > Project > Settings > Environment Variables:
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Browser usage:
//   fetch('/api/branch-login', { method:'POST',
//     headers:{ 'Content-Type':'application/json', Authorization:'Bearer ' + session.access_token },
//     body: JSON.stringify({ action:'create', username:'staff-main', password:'...', branch_id:'...', role:'staff' }) })
//   actions: create | reset (user_id, password) | remove (user_id)
import { createClient } from '@supabase/supabase-js';

const bad = (res, code, error) => res.status(code).json({ ok: false, error });

export default async function handler(req, res) {
  if (req.method !== 'POST') return bad(res, 405, 'Use POST');
  const { SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY } = process.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) return bad(res, 500, 'Server is not configured');

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return bad(res, 401, 'Sign in first');

  // 1) who is calling? Ask the database as that user.
  const asUser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: ctx, error: ctxErr } = await asUser.rpc('my_context');
  if (ctxErr || !ctx || ctx.role !== 'owner' || ctx.status !== 'active') return bad(res, 403, 'Owners only');

  // 2) privileged client, used only after the owner check above
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const body = req.body || {};
  const { action } = body;

  try {
    if (action === 'create') {
      const username = String(body.username || '').trim().toLowerCase();
      const password = String(body.password || '');
      const role = body.role === 'manager' ? 'manager' : 'staff';
      if (!/^[a-z0-9][a-z0-9._-]{2,29}$/.test(username)) return bad(res, 400, 'Username: 3 to 30 letters, numbers, dot, dash or underscore');
      if (password.length < 8) return bad(res, 400, 'Password needs at least 8 characters');

      // the branch must belong to the owner's tenant (row level security does the check)
      const { data: branch } = await asUser.from('branches').select('id,name').eq('id', body.branch_id).maybeSingle();
      if (!branch) return bad(res, 400, 'Unknown branch');

      const email = `${username}@${ctx.slug}.coffrenuer.app`;   // not a real mailbox, only a unique login name
      const { data: created, error: cErr } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (cErr) return bad(res, 400, /already|registered/i.test(cErr.message) ? 'That username is taken' : cErr.message);

      const { error: pErr } = await admin.from('profiles').insert({
        id: created.user.id, tenant_id: ctx.tenant_id, role, branch_id: branch.id,
        username, display_name: body.display_name || `${branch.name} ${role}`,
      });
      if (pErr) { await admin.auth.admin.deleteUser(created.user.id); return bad(res, 400, pErr.message); }
      return res.status(200).json({ ok: true, user_id: created.user.id, username });
    }

    if (action === 'reset' || action === 'remove') {
      const { data: target } = await admin.from('profiles').select('id,tenant_id,role').eq('id', body.user_id).maybeSingle();
      if (!target || target.tenant_id !== ctx.tenant_id) return bad(res, 404, 'Login not found');
      if (target.role === 'owner' || target.id === ctx.user_id) return bad(res, 400, 'Owner logins cannot be changed here');

      if (action === 'reset') {
        const password = String(body.password || '');
        if (password.length < 8) return bad(res, 400, 'Password needs at least 8 characters');
        const { error } = await admin.auth.admin.updateUserById(target.id, { password });
        if (error) return bad(res, 400, error.message);
        return res.status(200).json({ ok: true });
      }
      const { error } = await admin.auth.admin.deleteUser(target.id);   // profile row is removed by cascade
      if (error) return bad(res, 400, error.message);
      return res.status(200).json({ ok: true });
    }

    return bad(res, 400, 'Unknown action');
  } catch (e) {
    return bad(res, 500, 'Something went wrong');
  }
}
