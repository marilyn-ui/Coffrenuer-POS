# Coffrenuer POS (multi-tenant): Supabase + Vercel launch guide

## The model
```
Platform (you)
 └─ Tenant (a business: "Brew Bros Coffee", shop code "brewbros")
     ├─ Owner login (real email) ......... sees every branch of that tenant
     ├─ Branch A ── manager / staff logins (one shared login per branch), employees clock in with PINs
     └─ Branch B ── ...
```
Every row in the database carries a `tenant_id`, and row level security only lets a signed-in user touch rows of their own tenant (and, for staff and managers, their own branch). Tenant A can never see tenant B, even if someone tampers with the app in the browser.

| Role | Can do |
|---|---|
| **Owner** | All branches in their tenant: menu and prices, branches, employees, branch logins, settings, dashboards, void orders |
| **Manager** | Their branch: sales, stock, attendance corrections, void orders |
| **Staff** (shared branch login) | Their branch: ring up sales, edit stock, time clock |
| **Platform admin** (you) | List tenants, suspend or reactivate them, set plan and branch limit |

## How people sign in
- **Owner:** email + password. This is a normal Supabase Auth sign-up.
- **Branch logins (manager/staff):** *shop code* + *username* + password, for example `brewbros` / `staff-main` / `********`. Behind the scenes the login is `staff-main@brewbros.coffrenuer.app` (not a real mailbox, just a unique name), which is why usernames can repeat across tenants.
- **Employees at the time clock:** tap name, enter their own 4-digit PIN, selfie.

## 1. Create the Supabase project
1. Create a project in the **Singapore** region (closest to the Philippines).
2. SQL Editor: paste all of `supabase/schema.sql` and run it (try it in a test project first).
3. Authentication settings:
   - allow new sign-ups **on** (new businesses register themselves)
   - require **email confirmation** on
   - turn on leaked-password protection
4. Make yourself the platform admin: sign up once, then run
   ```sql
   insert into public.platform_admins (user_id) select id from auth.users where email = 'you@yourcompany.com';
   ```

## 2. What a new business does (inside the app)
1. Signs up with email and password, confirms the email.
2. Enters business name, **shop code** (3 to 32 letters, numbers, dashes) and the first branch. The app calls `create_tenant(...)`.
3. Optionally presses "Load sample menu" (`seed_sample_menu()`), or builds their own.
4. Adds branches (up to the plan limit, 2 on the free trial), then creates branch logins and employees.

## 3. Keys
Project Settings > API:
- **Project URL** and **anon key** go in `config.js` (public, safe in the browser).
- **service_role key**: *only* as a Vercel environment variable (below). Never in `config.js`, never in GitHub, never in the browser.

## 4. Deploy on Vercel
1. Push the folder to GitHub (`index.html`, `config.js`, `vercel.json`, `package.json`, `api/`, `supabase/`).
2. Vercel > Add New > Project > import it. Framework **Other**, no build command.
3. Vercel > Settings > Environment Variables (Production), add:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`   (mark it Sensitive)
4. Redeploy. The `api/branch-login.js` function lets owners create, reset and remove branch logins. It first checks, as the signed-in user, that the caller is an active owner, and it only touches logins in that owner's tenant.
5. Add your domain in Settings > Domains. `vercel.json` already allows the camera for your own site.

## 5. Before the first customer
- Remove sample logins and demo hints from the app.
- Test with **two tenants** at the same time and confirm each sees only its own data. Try a staff login from tenant A and check it cannot see branch B or tenant B.
- Test a suspended tenant (`select public.platform_set_tenant('<tenant id>', 'suspended', null, null);`): its users should be blocked and the app should say so.
- Test printing a receipt and a kitchen copy at each branch.
- Backups: use a paid Supabase plan (daily backups). A free project has no real backups and can pause when idle.
- The app needs internet to take orders. Keep a mobile hotspot at each branch.
- Billing is not built in. `plan`, `status` and `max_branches` on the tenant are ready to connect to a payment provider later.

## What the database enforces
- Tenant isolation on every table, plus composite foreign keys so a row can't point at another tenant's menu, branch or stock item.
- Suspended tenants see nothing and can't write anything.
- A sale is created only by `place_order`: prices are re-read from the database, the item must be sold at that branch, stock for that branch is checked and deducted, and the order is numbered, all in one step.
- Clock-in needs the employee's PIN, only at an assigned branch, with a 5-minute lock after 5 wrong tries.
- Selfies live in a private bucket, filed as `<tenant>/<branch>/<employee>/...`, and policies match that path to the user's tenant and branch.
- Plan limit on the number of branches per tenant.
- Times for "today" use the Asia/Manila time zone.
