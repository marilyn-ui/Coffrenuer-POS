-- =====================================================================
-- Coffrenuer POS: MULTI-TENANT + MULTI-BRANCH schema for Supabase
-- Run this whole file once in: Supabase dashboard > SQL Editor > New query
-- Test it in a throwaway project first.
--
-- Structure
--   tenant (a business that uses Coffrenuer)  ->  branches  ->  orders, stock, attendance
--   Every row carries a tenant_id, and row level security only ever lets a signed-in
--   user touch rows of THEIR tenant. One tenant can never see another.
--
-- Roles inside a tenant
--   owner    all branches of the tenant, menu, prices, staff, settings
--   manager  one branch: sales, stock, attendance, void orders
--   staff    one branch: ring up sales, edit stock, time clock (the shared branch login)
-- Platform admin (you, the operator) is separate: see platform_admins at the bottom.
--
-- Times use the Asia/Manila time zone where "today" matters.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tenants & branches ----------
create table if not exists public.tenants (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$'),   -- the "shop code" used at login
  name text not null,
  status text not null default 'active' check (status in ('active','suspended')),
  plan text not null default 'trial',
  max_branches int not null default 2,
  created_at timestamptz not null default now()
);

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null check (code ~ '^[A-Z0-9]{2,6}$'),
  name text not null,
  address text not null default '',
  phone text not null default '',
  next_order_no bigint not null default 1001,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, code)
);

-- every Supabase Auth user belongs to exactly one tenant
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  role text not null check (role in ('owner','manager','staff')),
  branch_id uuid references public.branches(id) on delete restrict,
  username text,
  display_name text,
  check ((role = 'owner' and branch_id is null) or (role in ('manager','staff') and branch_id is not null))
);

-- ---------- who am I? (all return null/false for suspended tenants, which blocks all data) ----------
create or replace function public.my_tenant() returns uuid
language sql stable security definer set search_path = public as $$
  select p.tenant_id from public.profiles p join public.tenants t on t.id = p.tenant_id
   where p.id = auth.uid() and t.status = 'active';
$$;
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select p.role from public.profiles p join public.tenants t on t.id = p.tenant_id
   where p.id = auth.uid() and t.status = 'active';
$$;
create or replace function public.my_branch() returns uuid
language sql stable security definer set search_path = public as $$
  select p.branch_id from public.profiles p join public.tenants t on t.id = p.tenant_id
   where p.id = auth.uid() and t.status = 'active';
$$;
create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$ select public.my_role() = 'owner'; $$;
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$ select public.my_role() is not null; $$;
create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

-- What the app calls right after sign-in (works even if the tenant is suspended, so it can say so).
create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('user_id', p.id, 'role', p.role, 'tenant_id', p.tenant_id, 'tenant_name', t.name,
                               'slug', t.slug, 'status', t.status, 'plan', t.plan, 'max_branches', t.max_branches,
                               'branch_id', p.branch_id, 'is_platform_admin', public.is_platform_admin())
       from public.profiles p join public.tenants t on t.id = p.tenant_id where p.id = auth.uid()),
    jsonb_build_object('is_platform_admin', public.is_platform_admin()));
$$;

-- ---------- shared (per tenant) catalog ----------
create table if not exists public.tenant_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  name text not null,
  footer text not null default 'Thank you! Come again.',
  kitchen_default boolean not null default false
);

create table if not exists public.categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  name text not null,
  sort int not null default 0,
  unique (tenant_id, id),
  unique (tenant_id, name)
);

create table if not exists public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  name text not null,
  unit text not null,
  unique (tenant_id, id)
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  category_id uuid not null,
  name text not null,
  price numeric(10,2) not null check (price >= 0),
  active boolean not null default true,
  hidden_branch_ids uuid[] not null default '{}',     -- branches where this item is NOT sold
  mod_group_ids uuid[] not null default '{}',
  unique (tenant_id, id),
  foreign key (tenant_id, category_id) references public.categories (tenant_id, id) on delete restrict
);

create table if not exists public.product_ingredients (
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  product_id uuid not null,
  item_id uuid not null,
  qty numeric(12,2) not null check (qty > 0),
  primary key (product_id, item_id),
  foreign key (tenant_id, product_id) references public.products (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id) references public.inventory_items (tenant_id, id) on delete cascade
);

create table if not exists public.mod_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  name text not null,
  type text not null check (type in ('single','multi')),
  required boolean not null default false,
  category_ids uuid[] not null default '{}',
  unique (tenant_id, id)
);

create table if not exists public.mod_options (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  group_id uuid not null,
  name text not null,
  price numeric(10,2) not null default 0 check (price >= 0),
  is_default boolean not null default false,
  sort int not null default 0,
  foreign key (tenant_id, group_id) references public.mod_groups (tenant_id, id) on delete cascade
);

-- ---------- per-branch data ----------
create table if not exists public.branch_stock (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  branch_id uuid not null,
  item_id uuid not null,
  qty numeric(12,2) not null default 0 check (qty >= 0),
  low numeric(12,2) not null default 0,
  primary key (branch_id, item_id),
  foreign key (tenant_id, branch_id) references public.branches (tenant_id, id) on delete cascade,
  foreign key (tenant_id, item_id) references public.inventory_items (tenant_id, id) on delete cascade
);

-- every item gets a stock row (0) in every branch of its tenant, and every new branch gets a row per item
create or replace function public._rows_for_new_item() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.branch_stock (tenant_id, branch_id, item_id)
  select new.tenant_id, id, new.id from public.branches where tenant_id = new.tenant_id on conflict do nothing;
  return new;
end $$;
drop trigger if exists trg_new_item on public.inventory_items;
create trigger trg_new_item after insert on public.inventory_items for each row execute function public._rows_for_new_item();

create or replace function public._rows_for_new_branch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.branch_stock (tenant_id, branch_id, item_id)
  select new.tenant_id, new.id, id from public.inventory_items where tenant_id = new.tenant_id on conflict do nothing;
  return new;
end $$;
drop trigger if exists trg_new_branch on public.branches;
create trigger trg_new_branch after insert on public.branches for each row execute function public._rows_for_new_branch();

-- plan limit: a tenant cannot create more branches than its plan allows
create or replace function public._branch_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.branches where tenant_id = new.tenant_id)
       >= (select max_branches from public.tenants where id = new.tenant_id) then
    raise exception 'Branch limit reached for your plan';
  end if;
  return new;
end $$;
drop trigger if exists trg_branch_limit on public.branches;
create trigger trg_branch_limit before insert on public.branches for each row execute function public._branch_limit();

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.my_tenant() references public.tenants(id) on delete cascade,
  name text not null,
  title text not null default 'Staff',
  pin_hash text not null,                       -- bcrypt hash, never the PIN itself
  active boolean not null default true,
  branch_ids uuid[] not null default '{}',
  photo_path text,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  unique (tenant_id, id)
);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete restrict,
  order_no bigint not null,
  created_at timestamptz not null default now(),
  cashier_id uuid references public.employees(id) on delete set null,
  cashier_name text not null,
  order_type text not null check (order_type in ('Dine-in','Take-out')),
  subtotal numeric(12,2) not null,
  discount numeric(12,2) not null default 0,
  discount_label text not null default '',
  total numeric(12,2) not null,
  pay_method text not null check (pay_method in ('Cash','GCash','Card')),
  tendered numeric(12,2) not null,
  change_amount numeric(12,2) not null default 0,
  reference text not null default '',
  kitchen_copy boolean not null default false,
  voided boolean not null default false,
  voided_at timestamptz,
  created_by uuid default auth.uid(),
  unique (branch_id, order_no)
);
create index if not exists orders_tenant_branch_created_idx on public.orders (tenant_id, branch_id, created_at desc);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete restrict,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  category text,
  unit_price numeric(10,2) not null,
  qty int not null check (qty > 0),
  options jsonb not null default '[]'::jsonb
);
create index if not exists order_items_order_idx on public.order_items (order_id);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete restrict,
  employee_id uuid references public.employees(id) on delete set null,
  employee_name text not null,
  clock_in timestamptz not null default now(),
  clock_out timestamptz,
  photo_path text,
  auto_closed boolean not null default false
);
create index if not exists attendance_tenant_branch_in_idx on public.attendance (tenant_id, branch_id, clock_in desc);

-- ---------- row level security ----------
alter table public.tenants             enable row level security;
alter table public.platform_admins     enable row level security;
alter table public.branches            enable row level security;
alter table public.profiles            enable row level security;
alter table public.tenant_settings     enable row level security;
alter table public.categories          enable row level security;
alter table public.inventory_items     enable row level security;
alter table public.products            enable row level security;
alter table public.product_ingredients enable row level security;
alter table public.mod_groups          enable row level security;
alter table public.mod_options         enable row level security;
alter table public.branch_stock        enable row level security;
alter table public.employees           enable row level security;
alter table public.orders              enable row level security;
alter table public.order_items         enable row level security;
alter table public.attendance          enable row level security;

revoke all on all tables in schema public from anon;
revoke all on public.platform_admins from authenticated;          -- reachable only through security definer functions

-- tenants: members read their own; only the name is editable (by the owner); platform admin reads/edits all via RPC
revoke insert, update, delete on public.tenants from authenticated;
grant update (name) on public.tenants to authenticated;
drop policy if exists tenant_read on public.tenants;
create policy tenant_read on public.tenants for select to authenticated using (id = public.my_tenant() or public.is_platform_admin());
drop policy if exists tenant_rename on public.tenants;
create policy tenant_rename on public.tenants for update to authenticated using (id = public.my_tenant() and public.is_owner()) with check (id = public.my_tenant() and public.is_owner());

-- profiles: you see yourself; the owner sees everyone in the tenant. Created only by create_tenant / the server API.
revoke insert, update, delete on public.profiles from authenticated;
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or (tenant_id = public.my_tenant() and public.is_owner()));

-- tenant-wide reads for every member of that tenant
do $$
declare t text;
begin
  foreach t in array array['tenant_settings','categories','inventory_items','products','product_ingredients','mod_groups','mod_options'] loop
    execute format('drop policy if exists read_members on public.%I', t);
    execute format('create policy read_members on public.%I for select to authenticated using (tenant_id = public.my_tenant())', t);
  end loop;
end $$;

-- the owner edits the catalog
do $$
declare t text;
begin
  foreach t in array array['categories','inventory_items','products','product_ingredients','mod_groups','mod_options'] loop
    execute format('drop policy if exists owner_write on public.%I', t);
    execute format('create policy owner_write on public.%I for all to authenticated using (tenant_id = public.my_tenant() and public.is_owner()) with check (tenant_id = public.my_tenant() and public.is_owner())', t);
  end loop;
end $$;
drop policy if exists owner_update on public.tenant_settings;
create policy owner_update on public.tenant_settings for update to authenticated
  using (tenant_id = public.my_tenant() and public.is_owner()) with check (tenant_id = public.my_tenant() and public.is_owner());

-- branches: owner sees and edits all of the tenant's; manager/staff see only their own
revoke insert, update, delete on public.branches from authenticated;
grant insert (code, name, address, phone, active), update (code, name, address, phone, active) on public.branches to authenticated;
grant delete on public.branches to authenticated;
drop policy if exists branch_read on public.branches;
create policy branch_read on public.branches for select to authenticated
  using (tenant_id = public.my_tenant() and (public.is_owner() or id = public.my_branch()));
drop policy if exists branch_owner_write on public.branches;
create policy branch_owner_write on public.branches for all to authenticated
  using (tenant_id = public.my_tenant() and public.is_owner()) with check (tenant_id = public.my_tenant() and public.is_owner());
alter table public.branches alter column tenant_id set default public.my_tenant();

-- branch-scoped reads: owner sees every branch of the tenant, others only their branch
do $$
declare t text;
begin
  foreach t in array array['branch_stock','orders','order_items','attendance'] loop
    execute format('drop policy if exists read_scoped on public.%I', t);
    execute format('create policy read_scoped on public.%I for select to authenticated using (tenant_id = public.my_tenant() and (public.is_owner() or branch_id = public.my_branch()))', t);
  end loop;
end $$;

-- stock counts: staff can edit their own branch (quantity and alert level only)
revoke insert, update, delete on public.branch_stock from authenticated;
grant update (qty, low) on public.branch_stock to authenticated;
drop policy if exists stock_update on public.branch_stock;
create policy stock_update on public.branch_stock for update to authenticated
  using (tenant_id = public.my_tenant() and (public.is_owner() or branch_id = public.my_branch()))
  with check (tenant_id = public.my_tenant() and (public.is_owner() or branch_id = public.my_branch()));

-- sales are written only by place_order() / voided only by void_order()
revoke insert, update, delete on public.orders, public.order_items from authenticated;

-- attendance is written only by clock_in / clock_out; the owner (or a manager) can correct the clock-out time
revoke insert, update, delete on public.attendance from authenticated;
grant update (clock_out) on public.attendance to authenticated;
drop policy if exists fix_clock_out on public.attendance;
create policy fix_clock_out on public.attendance for update to authenticated
  using (tenant_id = public.my_tenant() and (public.is_owner() or (public.my_role() = 'manager' and branch_id = public.my_branch())))
  with check (tenant_id = public.my_tenant());

-- employees: the browser can read everything EXCEPT the PIN hash and lockout fields
revoke all on public.employees from authenticated;
grant select (id, tenant_id, name, title, active, branch_ids, photo_path, created_at) on public.employees to authenticated;
grant delete on public.employees to authenticated;
drop policy if exists read_scoped on public.employees;
create policy read_scoped on public.employees for select to authenticated
  using (tenant_id = public.my_tenant() and (public.is_owner() or public.my_branch() = any (branch_ids)));
drop policy if exists owner_delete on public.employees;
create policy owner_delete on public.employees for delete to authenticated using (tenant_id = public.my_tenant() and public.is_owner());
-- (employees are created and edited only through owner_save_employee below)

-- ---------- selfie storage: <tenant_id>/<branch_id>/<employee_id>/<file>.jpg ----------
insert into storage.buckets (id, name, public) values ('selfies', 'selfies', false) on conflict (id) do nothing;
drop policy if exists selfies_upload on storage.objects;
create policy selfies_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'selfies' and (storage.foldername(name))[1] = public.my_tenant()::text
              and (public.is_owner() or (storage.foldername(name))[2] = public.my_branch()::text));
drop policy if exists selfies_read on storage.objects;
create policy selfies_read on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and (storage.foldername(name))[1] = public.my_tenant()::text
         and (public.is_owner() or (storage.foldername(name))[2] = public.my_branch()::text));

-- ---------- sign-up: a new business creates its tenant ----------
-- Call this right after the owner signs up with Supabase Auth (email + password).
create or replace function public.create_tenant(p_name text, p_slug text, p_branch_name text, p_branch_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tid uuid; bid uuid; v_slug text := lower(trim(p_slug));
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if exists (select 1 from public.profiles where id = auth.uid()) then raise exception 'This account already belongs to a shop'; end if;
  if v_slug in ('www','app','api','admin','support','help','mail','billing') then raise exception 'That shop code is reserved'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$' then raise exception 'Shop code: 3 to 32 letters, numbers or dashes'; end if;
  if exists (select 1 from public.tenants where tenants.slug = v_slug) then raise exception 'That shop code is already taken'; end if;

  insert into public.tenants (slug, name) values (v_slug, trim(p_name)) returning id into tid;
  insert into public.tenant_settings (tenant_id, name) values (tid, trim(p_name));
  insert into public.branches (tenant_id, code, name) values (tid, upper(trim(p_branch_code)), trim(p_branch_name)) returning id into bid;
  insert into public.profiles (id, tenant_id, role, display_name) values (auth.uid(), tid, 'owner', 'Owner');
  return jsonb_build_object('tenant_id', tid, 'branch_id', bid, 'slug', v_slug);
end $$;

-- ---------- server functions ----------

-- PIN check with lockout (5 wrong tries = 5 minute lock). Returns 'ok','wrong','locked' or 'missing'.
create or replace function public._check_pin(p_emp uuid, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare e public.employees;
begin
  select * into e from public.employees where id = p_emp and tenant_id = public.my_tenant() and active for update;
  if not found then return 'missing'; end if;
  if e.locked_until is not null and e.locked_until > now() then return 'locked'; end if;
  if e.pin_hash = extensions.crypt(coalesce(p_pin, ''), e.pin_hash) then
    update public.employees set failed_attempts = 0, locked_until = null where id = e.id;
    return 'ok';
  end if;
  update public.employees set
    failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
    locked_until    = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' else locked_until end
  where id = e.id;
  return 'wrong';
end $$;

-- Clock in at the branch of the signed-in manager/staff login.
create or replace function public.clock_in(p_employee uuid, p_pin text, p_photo_path text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  t uuid := public.my_tenant(); b uuid := public.my_branch(); r text; e public.employees; a public.attendance;
  today_start timestamptz := date_trunc('day', now() at time zone 'Asia/Manila') at time zone 'Asia/Manila';
begin
  if t is null or b is null then raise exception 'Use a branch login to clock in'; end if;
  select * into e from public.employees where id = p_employee and tenant_id = t and active;
  if not found then return jsonb_build_object('ok', false, 'error', 'missing'); end if;
  if not (b = any (e.branch_ids)) then return jsonb_build_object('ok', false, 'error', 'not_assigned'); end if;

  r := public._check_pin(p_employee, p_pin);
  if r <> 'ok' then return jsonb_build_object('ok', false, 'error', r); end if;

  update public.attendance set
    clock_out = (date_trunc('day', clock_in at time zone 'Asia/Manila') + interval '23 hours 59 minutes 59 seconds') at time zone 'Asia/Manila',
    auto_closed = true
  where tenant_id = t and employee_id = p_employee and clock_out is null and clock_in < today_start;

  perform 1 from public.attendance
   where tenant_id = t and employee_id = p_employee and clock_out is null and clock_in >= today_start and branch_id <> b;
  if found then return jsonb_build_object('ok', false, 'error', 'clocked_in_elsewhere'); end if;

  select * into a from public.attendance
   where tenant_id = t and employee_id = p_employee and clock_out is null and clock_in >= today_start and branch_id = b limit 1;
  if found then
    update public.attendance set photo_path = coalesce(p_photo_path, photo_path) where id = a.id returning * into a;
  else
    insert into public.attendance (tenant_id, branch_id, employee_id, employee_name, photo_path)
    values (t, b, p_employee, e.name, p_photo_path) returning * into a;
  end if;
  if p_photo_path is not null then
    update public.employees set photo_path = p_photo_path where id = p_employee;
  end if;
  return jsonb_build_object('ok', true, 'attendance', to_jsonb(a));
end $$;

create or replace function public.clock_out(p_employee uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid := public.my_tenant(); b uuid := public.my_branch(); r text;
begin
  if t is null or b is null then raise exception 'Use a branch login to clock out'; end if;
  r := public._check_pin(p_employee, p_pin);
  if r <> 'ok' then return jsonb_build_object('ok', false, 'error', r); end if;
  update public.attendance set clock_out = now()
   where tenant_id = t and employee_id = p_employee and clock_out is null and branch_id = b;
  return jsonb_build_object('ok', true);
end $$;

-- Owner: create or edit an employee. Leave p_pin empty to keep the current PIN.
create or replace function public.owner_save_employee(
  p_id uuid, p_name text, p_title text, p_pin text, p_active boolean, p_branch_ids uuid[]
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid := public.my_tenant(); rid uuid; ids uuid[] := coalesce(p_branch_ids, '{}');
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  if exists (select 1 from unnest(ids) x where not exists (select 1 from public.branches b where b.id = x and b.tenant_id = t)) then
    raise exception 'Unknown branch';
  end if;
  if coalesce(p_pin, '') <> '' and p_pin !~ '^\d{4}$' then raise exception 'PIN must be 4 digits'; end if;
  if p_id is null then
    if coalesce(p_pin, '') = '' then raise exception 'A PIN is required'; end if;
    insert into public.employees (tenant_id, name, title, pin_hash, active, branch_ids)
    values (t, trim(p_name), coalesce(nullif(p_title, ''), 'Staff'), extensions.crypt(p_pin, extensions.gen_salt('bf')), coalesce(p_active, true), ids)
    returning id into rid;
  else
    update public.employees set
      name = trim(p_name), title = coalesce(nullif(p_title, ''), 'Staff'), active = coalesce(p_active, true), branch_ids = ids,
      pin_hash = case when coalesce(p_pin, '') = '' then pin_hash else extensions.crypt(p_pin, extensions.gen_salt('bf')) end,
      failed_attempts = 0, locked_until = null
    where id = p_id and tenant_id = t;
    if not found then raise exception 'Employee not found'; end if;
    rid := p_id;
  end if;
  return rid;
end $$;

-- Add a stock item. Staff add it to their own branch; the item then exists (at 0) in every branch of the tenant.
create or replace function public.add_stock_item(p_branch uuid, p_name text, p_unit text, p_qty numeric, p_low numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid := public.my_tenant(); b uuid; iid uuid;
begin
  if t is null then raise exception 'Not allowed'; end if;
  b := case when public.is_owner() then p_branch else public.my_branch() end;
  if b is null or not exists (select 1 from public.branches where id = b and tenant_id = t) then raise exception 'No branch selected'; end if;
  select id into iid from public.inventory_items where tenant_id = t and lower(name) = lower(trim(p_name)) and unit = trim(p_unit) limit 1;
  if iid is null then
    insert into public.inventory_items (tenant_id, name, unit) values (t, trim(p_name), trim(p_unit)) returning id into iid;
  end if;
  update public.branch_stock set qty = greatest(0, coalesce(p_qty, 0)), low = greatest(0, coalesce(p_low, 0))
   where tenant_id = t and branch_id = b and item_id = iid;
  return iid;
end $$;

-- Ring up a sale. Prices come from the database, not the browser. Stock for THIS branch is deducted
-- in the same transaction, so two tablets selling at once cannot oversell or lose a count.
-- Branch logins always sell at their own branch; the owner passes p_branch.
-- p_items example: [{"product_id":"...","qty":2,"option_ids":["...","..."]}]
create or replace function public.place_order(
  p_branch uuid, p_items jsonb, p_type text, p_discount_pct numeric, p_discount_label text, p_pay text,
  p_tendered numeric, p_ref text, p_kitchen boolean, p_cashier uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  t uuid := public.my_tenant(); b uuid; br public.branches; it jsonb; prod public.products; n_qty int; unit numeric;
  opts jsonb; opt_total numeric; subtotal numeric := 0; disc numeric; tot numeric; tend numeric;
  oid uuid := gen_random_uuid(); ono bigint; cname text; cat_name text;
  lines jsonb := '[]'::jsonb; ing record; o public.orders;
begin
  if t is null then raise exception 'Not allowed'; end if;
  b := case when public.is_owner() then p_branch else public.my_branch() end;
  if b is null then raise exception 'No branch selected'; end if;
  select * into br from public.branches where id = b and tenant_id = t and active;
  if not found then raise exception 'Branch not found or inactive'; end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'The order is empty'; end if;
  if p_discount_pct not in (0, 10, 20) then raise exception 'Invalid discount'; end if;
  if p_type not in ('Dine-in', 'Take-out') then raise exception 'Invalid order type'; end if;

  if p_cashier is not null then
    select name into cname from public.employees where id = p_cashier and tenant_id = t and active and b = any (branch_ids);
  end if;
  if cname is null then cname := case when public.is_owner() then 'Owner' else 'Shared staff' end; end if;

  for it in select value from jsonb_array_elements(p_items) loop
    n_qty := (it->>'qty')::int;
    if n_qty is null or n_qty < 1 or n_qty > 99 then raise exception 'Invalid quantity'; end if;
    select * into prod from public.products
     where tenant_id = t and id = (it->>'product_id')::uuid and active and not (b = any (hidden_branch_ids));
    if not found then raise exception 'An item is not available at this branch'; end if;
    select name into cat_name from public.categories where tenant_id = t and id = prod.category_id;

    select coalesce(jsonb_agg(jsonb_build_object('g', g.name, 'n', o2.name, 'price', o2.price)), '[]'::jsonb),
           coalesce(sum(o2.price), 0)
      into opts, opt_total
      from public.mod_options o2
      join public.mod_groups g on g.id = o2.group_id and g.tenant_id = o2.tenant_id
     where o2.tenant_id = t
       and o2.id in (select x::uuid from jsonb_array_elements_text(coalesce(it->'option_ids', '[]'::jsonb)) x)
       and (prod.category_id = any (g.category_ids) or g.id = any (prod.mod_group_ids));

    unit := prod.price + opt_total;
    subtotal := subtotal + unit * n_qty;
    lines := lines || jsonb_build_object('product_id', prod.id, 'name', prod.name, 'category', cat_name,
                                         'unit_price', unit, 'qty', n_qty, 'options', opts);

    for ing in
      select pi.item_id, pi.qty as need, ii.name as item_name
        from public.product_ingredients pi join public.inventory_items ii on ii.id = pi.item_id
       where pi.tenant_id = t and pi.product_id = prod.id
    loop
      update public.branch_stock set qty = qty - ing.need * n_qty
       where tenant_id = t and branch_id = b and item_id = ing.item_id and qty >= ing.need * n_qty;
      if not found then raise exception 'Not enough stock: %', ing.item_name; end if;
    end loop;
  end loop;

  disc := round(subtotal * p_discount_pct / 100, 2);
  tot := subtotal - disc;
  if p_pay = 'Cash' then
    if p_tendered is null or p_tendered < tot then raise exception 'Cash received is less than the total'; end if;
    tend := p_tendered;
  elsif p_pay in ('GCash', 'Card') then
    tend := tot;
  else
    raise exception 'Invalid payment method';
  end if;

  update public.branches set next_order_no = next_order_no + 1 where id = b and tenant_id = t returning next_order_no - 1 into ono;

  insert into public.orders (id, tenant_id, branch_id, order_no, cashier_id, cashier_name, order_type, subtotal, discount, discount_label,
                             total, pay_method, tendered, change_amount, reference, kitchen_copy)
  values (oid, t, b, ono, case when cname in ('Owner', 'Shared staff') then null else p_cashier end, cname, p_type, subtotal, disc,
          case when p_discount_pct > 0 then coalesce(p_discount_label, '') else '' end,
          tot, p_pay, tend, greatest(0, tend - tot), coalesce(p_ref, ''), coalesce(p_kitchen, false))
  returning * into o;

  insert into public.order_items (tenant_id, order_id, branch_id, product_id, name, category, unit_price, qty, options)
  select t, oid, b, (x.l->>'product_id')::uuid, x.l->>'name', x.l->>'category', (x.l->>'unit_price')::numeric, (x.l->>'qty')::int, x.l->'options'
    from jsonb_array_elements(lines) as x(l);

  return to_jsonb(o) || jsonb_build_object('items', lines, 'branch_code', br.code);
end $$;

-- Owner (any branch) or manager (own branch): void a sale and put the ingredients back in that branch's stock.
create or replace function public.void_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := public.my_tenant(); o public.orders;
begin
  if t is null or public.my_role() not in ('owner', 'manager') then raise exception 'Owner or manager only'; end if;
  select * into o from public.orders where id = p_order and tenant_id = t;
  if not found then raise exception 'Order not found'; end if;
  if public.my_role() = 'manager' and o.branch_id <> public.my_branch() then raise exception 'Not your branch'; end if;
  if o.voided then return; end if;
  update public.orders set voided = true, voided_at = now() where id = p_order;
  update public.branch_stock bs set qty = bs.qty + s.amount
    from (select pi.item_id, sum(pi.qty * oi.qty) as amount
            from public.order_items oi join public.product_ingredients pi on pi.product_id = oi.product_id and pi.tenant_id = t
           where oi.order_id = p_order group by pi.item_id) s
   where bs.tenant_id = t and bs.branch_id = o.branch_id and bs.item_id = s.item_id;
end $$;

-- Sample menu for a brand-new tenant (owner presses a button; skip it to enter your own menu).
create or replace function public.seed_sample_menu() returns void
language plpgsql security definer set search_path = public as $$
declare t uuid := public.my_tenant(); drinks uuid[];
begin
  if not public.is_owner() then raise exception 'Owner only'; end if;
  if exists (select 1 from public.categories where tenant_id = t) then return; end if;

  insert into public.categories (tenant_id, name, sort) values (t,'Coffee',1), (t,'Non-coffee',2), (t,'Pastry',3);

  drop table if exists _seed_items;
  create temp table _seed_items on commit drop as
    select * from (values
      ('Coffee beans','g',6000,1500), ('Fresh milk','ml',14000,3500), ('Cups (12 oz)','pcs',420,100), ('Lids','pcs',420,100),
      ('Caramel syrup','ml',1600,400), ('Chocolate powder','g',2200,500), ('Matcha powder','g',900,250), ('Fruit tea base','ml',2400,600),
      ('Croissants','pcs',24,6), ('Banana bread','slice',22,6), ('Choco chip cookies','pcs',36,10), ('Ensaymada','pcs',20,6)
    ) x(n, u, q, l);
  insert into public.inventory_items (tenant_id, name, unit) select t, n, u from _seed_items;   -- trigger adds a 0 stock row per branch
  update public.branch_stock bs set qty = s.q, low = s.l
    from _seed_items s join public.inventory_items i on i.tenant_id = t and i.name = s.n
   where bs.tenant_id = t and bs.item_id = i.id;

  insert into public.products (tenant_id, category_id, name, price)
  select t, c.id, v.n, v.p from (values
    ('Coffee','Espresso',90),('Coffee','Americano',110),('Coffee','Iced Americano',120),('Coffee','Cafe Latte',130),
    ('Coffee','Iced Latte',140),('Coffee','Cappuccino',130),('Coffee','Flat White',140),('Coffee','Spanish Latte',150),
    ('Coffee','Caramel Macchiato',160),('Coffee','Mocha',150),
    ('Non-coffee','Matcha Latte',160),('Non-coffee','Hot Chocolate',140),('Non-coffee','Fruit Tea',110),
    ('Non-coffee','Brown Sugar Milk Tea',140),
    ('Pastry','Croissant',95),('Pastry','Banana Bread',85),('Pastry','Choco Chip Cookie',70),('Pastry','Ensaymada',80)
  ) v(cat, n, p) join public.categories c on c.tenant_id = t and c.name = v.cat;

  insert into public.product_ingredients (tenant_id, product_id, item_id, qty)
  select t, p.id, i.id, 1 from public.products p
    join public.categories c on c.id = p.category_id and c.tenant_id = t and c.name in ('Coffee','Non-coffee')
    cross join public.inventory_items i where p.tenant_id = t and i.tenant_id = t and i.name in ('Cups (12 oz)','Lids');

  insert into public.product_ingredients (tenant_id, product_id, item_id, qty)
  select t, p.id, i.id, v.q from (values
    ('Espresso','Coffee beans',18),('Americano','Coffee beans',18),('Iced Americano','Coffee beans',18),
    ('Cafe Latte','Coffee beans',18),('Cafe Latte','Fresh milk',200),('Iced Latte','Coffee beans',18),('Iced Latte','Fresh milk',200),
    ('Cappuccino','Coffee beans',18),('Cappuccino','Fresh milk',150),('Flat White','Coffee beans',18),('Flat White','Fresh milk',160),
    ('Spanish Latte','Coffee beans',18),('Spanish Latte','Fresh milk',200),
    ('Caramel Macchiato','Coffee beans',18),('Caramel Macchiato','Fresh milk',180),('Caramel Macchiato','Caramel syrup',20),
    ('Mocha','Coffee beans',18),('Mocha','Fresh milk',180),('Mocha','Chocolate powder',20),
    ('Matcha Latte','Matcha powder',8),('Matcha Latte','Fresh milk',200),
    ('Hot Chocolate','Chocolate powder',30),('Hot Chocolate','Fresh milk',200),
    ('Fruit Tea','Fruit tea base',60),('Brown Sugar Milk Tea','Fresh milk',150),('Brown Sugar Milk Tea','Fruit tea base',40),
    ('Croissant','Croissants',1),('Banana Bread','Banana bread',1),('Choco Chip Cookie','Choco chip cookies',1),('Ensaymada','Ensaymada',1)
  ) v(pn, inm, q) join public.products p on p.tenant_id = t and p.name = v.pn
                  join public.inventory_items i on i.tenant_id = t and i.name = v.inm;

  select array_agg(id) into drinks from public.categories where tenant_id = t and name in ('Coffee','Non-coffee');
  insert into public.mod_groups (tenant_id, name, type, required, category_ids) values
    (t, 'Sugar level', 'single', true, drinks), (t, 'Add-ons', 'multi', false, drinks);

  insert into public.mod_options (tenant_id, group_id, name, price, is_default, sort)
  select t, g.id, v.n, v.p, v.d, v.s from (values
    ('Sugar level','0%',0,false,1),('Sugar level','25%',0,false,2),('Sugar level','50%',0,false,3),
    ('Sugar level','75%',0,false,4),('Sugar level','100%',0,true,5),
    ('Add-ons','Pearl',15,false,1),('Add-ons','Nata de coco',15,false,2),
    ('Add-ons','Coffee jelly',20,false,3),('Add-ons','Extra shot',30,false,4)
  ) v(gn, n, p, d, s) join public.mod_groups g on g.tenant_id = t and g.name = v.gn;
end $$;

-- ---------- platform admin (you, the operator) ----------
create or replace function public.platform_list_tenants() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform admin only'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', t.id, 'slug', t.slug, 'name', t.name, 'status', t.status, 'plan', t.plan, 'max_branches', t.max_branches, 'created_at', t.created_at,
      'branches', (select count(*) from public.branches b where b.tenant_id = t.id),
      'orders_30d', (select count(*) from public.orders o where o.tenant_id = t.id and o.created_at > now() - interval '30 days'))
    order by t.created_at desc) from public.tenants t), '[]'::jsonb);
end $$;

create or replace function public.platform_set_tenant(p_tenant uuid, p_status text, p_plan text, p_max_branches int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform admin only'; end if;
  update public.tenants set
    status = coalesce(p_status, status), plan = coalesce(p_plan, plan), max_branches = coalesce(p_max_branches, max_branches)
  where id = p_tenant;
end $$;

-- lock the functions down: signed-in users only
do $$
declare f text;
begin
  foreach f in array array[
    'public.create_tenant(text,text,text,text)', 'public.my_context()',
    'public.clock_in(uuid,text,text)', 'public.clock_out(uuid,text)',
    'public.owner_save_employee(uuid,text,text,text,boolean,uuid[])',
    'public.add_stock_item(uuid,text,text,numeric,numeric)',
    'public.place_order(uuid,jsonb,text,numeric,text,text,numeric,text,boolean,uuid)',
    'public.void_order(uuid)', 'public.seed_sample_menu()',
    'public.platform_list_tenants()', 'public.platform_set_tenant(uuid,text,text,int)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
revoke execute on function public._check_pin(uuid,text) from public, anon, authenticated;

-- =====================================================================
-- AFTER running this file
-- 1) Make yourself the platform admin: sign up once in your app (or add a user in Authentication > Users), then:
--      insert into public.platform_admins (user_id) select id from auth.users where email = 'you@yourcompany.com';
-- 2) Turn ON email confirmation and allow sign-ups (Authentication settings) so new businesses can register.
--    Each business owner signs up with a real email, then the app calls create_tenant(...).
-- 3) Branch/staff logins are created by the owner inside the app through the server API in /api/branch-login.js
--    (it needs the service_role key as a SERVER-ONLY environment variable on Vercel).
-- =====================================================================
