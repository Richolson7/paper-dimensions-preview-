-- =====================================================================
-- Paper Dimensions Command Center · Supabase schema v1
-- Run once in a NEW Supabase project: SQL Editor -> paste -> Run.
-- Phase 1 live: logins, roles, machines, floor events (realtime), training.
-- The rest of the tables are ready for phase 2 wiring.
-- =====================================================================

-- ---------- Roles and user profiles ----------
create type public.app_role as enum
  ('admin','manager','office','operator','material_handler','shipping','maintenance');

create table public.profiles (
  id              uuid primary key references auth.users on delete cascade,
  email           text,
  full_name       text,
  role            public.app_role not null default 'operator',
  default_machine text,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

-- Role helpers (security definer so policies can call them without recursion)
create or replace function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.has_role(variadic roles public.app_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and active and role = any(roles))
$$;

-- Every new login gets a profile. Role can be passed in invite metadata, else operator.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
          coalesce((new.raw_user_meta_data->>'role')::public.app_role, 'operator'));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- Plant setup ----------
create table public.machines (
  id           text primary key,             -- S1, S2 ... (stable id; name is what people see)
  name         text not null,
  max_width_in numeric not null,
  type         text,
  shift_target int,
  rated_fpm    int,
  sort         int default 0,
  active       boolean not null default true,
  updated_at   timestamptz not null default now()
);

create table public.bays (
  id          text primary key,              -- A, B, C ...
  description text
);

create table public.settings (
  key   text primary key,                    -- 'targets', 'lean_goal'
  value jsonb not null
);

-- ---------- Paper inventory ----------
create table public.master_rolls (
  id          text primary key,              -- MR-21008 or mill barcode
  grade       text not null,
  width_in    numeric not null,
  footage     int not null,
  location    text,                          -- A-01-1, STAGE-S2
  owner       text not null default 'PD stock',
  received_on date not null default current_date,
  status      text not null default 'in_rack'
              check (status in ('in_rack','held','staged','consumed')),
  held_for    text,
  updated_at  timestamptz not null default now()
);

create table public.roll_moves (
  id         bigint generated always as identity primary key,
  roll_id    text references public.master_rolls on delete cascade,
  kind       text not null check (kind in ('receive','move','pull','count')),
  from_loc   text,
  to_loc     text,
  created_by uuid default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);

create table public.paper_targets (
  grade           text primary key,
  source          text not null default 'PD buys' check (source in ('PD buys','Customer supplies')),
  min_masters     int not null default 0,
  max_masters     int not null default 0,
  cost_per_master numeric
);

-- ---------- Orders ----------
create table public.po_intake (
  id          uuid primary key default gen_random_uuid(),
  received_at timestamptz not null default now(),
  from_email  text,
  subject     text,
  file_name   text,
  parsed      jsonb,                         -- customer, po, grade, cuts, footage, masters, ship, core
  confidence  int,
  status      text not null default 'waiting' check (status in ('waiting','released','exception')),
  reason      text,
  shop_no     text
);

create table public.production_orders (
  shop_no            text primary key,
  po_no              text,
  customer           text not null,
  grade              text,
  cut_pattern        jsonb,                  -- [{"n":16,"w":2.5}]
  masters_needed     int,
  footage_per_master int,
  ship_date          date,
  core_size          text,
  machine_id         text references public.machines,
  paper_here         boolean default true,
  status             text not null default 'released'
                     check (status in ('released','running','done','shipped','hold')),
  created_by         uuid default auth.uid() references public.profiles,
  created_at         timestamptz not null default now()
);

create table public.order_rolls (
  shop_no text references public.production_orders on delete cascade,
  roll_id text references public.master_rolls,
  primary key (shop_no, roll_id)
);

-- ---------- Floor events (the realtime heartbeat) ----------
create table public.production_events (
  id         bigint generated always as identity primary key,
  client_id  uuid unique,                    -- set by the Chromebook so offline retries never double-count
  machine_id text not null references public.machines,
  shop_no    text,
  event_type text not null check (event_type in ('status','master_done','rolls_off','load_roll')),
  status     text check (status in ('Running','Changeover','Down','Idle')),
  reason     text,
  qty        int,
  roll_id    text,
  fpm        int,
  client_ts  timestamptz,                    -- when the operator tapped (even if offline)
  created_by uuid not null default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);
create index on public.production_events (machine_id, created_at desc);

-- Live line status for the dashboard
create view public.machine_live with (security_invoker = true) as
select m.id, m.name, m.sort,
  s.status, s.reason, s.created_at as status_at,
  coalesce((select sum(qty) from public.production_events e
            where e.machine_id = m.id and e.event_type = 'master_done'
              and e.created_at >= date_trunc('day', now())), 0) as masters_today,
  coalesce((select sum(qty) from public.production_events e
            where e.machine_id = m.id and e.event_type = 'rolls_off'
              and e.created_at >= date_trunc('day', now())), 0) as rolls_today
from public.machines m
left join lateral (
  select status, reason, created_at from public.production_events e
  where e.machine_id = m.id and e.event_type = 'status'
  order by created_at desc limit 1) s on true
where m.active;

-- ---------- Maintenance and safety ----------
create table public.work_orders (
  id           bigint generated always as identity primary key,
  asset        text not null,
  problem      text not null,
  priority     text not null default 'Med' check (priority in ('High','Med','Low')),
  status       text not null default 'Open' check (status in ('Open','In progress','Waiting parts','Done')),
  assigned_to  text,
  downtime_min int,
  created_by   uuid default auth.uid() references public.profiles,
  opened_at    timestamptz not null default now(),
  closed_at    timestamptz
);

create table public.pm_tasks (
  id             bigint generated always as identity primary key,
  asset          text not null,
  task           text not null,
  interval_hours int,
  interval_days  int,
  last_done      date,
  next_due       date
);

create table public.safety_docs (
  id          bigint generated always as identity primary key,
  title       text not null,
  kind        text,
  reviewed_on date,
  url         text
);

-- ---------- Supplies, shipping, receiving ----------
create table public.consumables (
  id           bigint generated always as identity primary key,
  name         text not null,
  category     text,
  supplier     text,
  usage_driver text,
  on_hand      numeric not null default 0,
  unit         text,
  use_14d      numeric,
  reorder_days int default 10,
  driven_item  boolean default false
);

create table public.inbound_loads (
  id        text primary key,
  source    text,
  kind      text,
  carrier   text,
  eta       timestamptz,
  for_order text,
  status    text not null default 'Expected' check (status in ('Expected','Unloading','Received'))
);

create table public.shipments (
  id        text primary key,
  customer  text,
  carrier   text,
  pickup_at timestamptz,
  pallets   int,
  rolls     int,
  weight_lb int,
  loaded    int not null default 0,
  status    text not null default 'In production'
            check (status in ('In production','Staged','Loading','Shipped'))
);

create table public.shipment_orders (
  shipment_id text references public.shipments on delete cascade,
  shop_no     text references public.production_orders,
  primary key (shipment_id, shop_no)
);

-- ---------- Training ----------
create table public.training_progress (
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  path    text not null,                     -- op, mh, sr, off, mt, mgr
  lesson  int  not null,
  done_at timestamptz not null default now(),
  primary key (user_id, path, lesson)
);

create table public.training_quiz (
  user_id  uuid not null default auth.uid() references public.profiles on delete cascade,
  path     text not null,
  score    int  not null,
  taken_at timestamptz not null default now(),
  primary key (user_id, path)
);

-- =====================================================================
-- Row level security: nobody sees anything without an active login.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['machines','bays','settings','master_rolls','roll_moves','paper_targets',
    'po_intake','production_orders','order_rolls','production_events','work_orders','pm_tasks',
    'safety_docs','consumables','inbound_loads','shipments','shipment_orders'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "signed-in users read" on public.%I for select to authenticated using (public.my_role() is not null)', t);
  end loop;
end $$;

-- Who can change what
create policy "admins and managers edit plant setup" on public.machines for all to authenticated
  using (public.has_role('admin','manager')) with check (public.has_role('admin','manager'));
create policy "admins and managers edit bays" on public.bays for all to authenticated
  using (public.has_role('admin','manager')) with check (public.has_role('admin','manager'));
create policy "admins and managers edit settings" on public.settings for all to authenticated
  using (public.has_role('admin','manager')) with check (public.has_role('admin','manager'));
create policy "admins and managers edit paper targets" on public.paper_targets for all to authenticated
  using (public.has_role('admin','manager')) with check (public.has_role('admin','manager'));

create policy "inventory people edit rolls" on public.master_rolls for all to authenticated
  using (public.has_role('admin','manager','office','material_handler','shipping'))
  with check (public.has_role('admin','manager','office','material_handler','shipping'));
create policy "inventory people log moves" on public.roll_moves for insert to authenticated
  with check (public.has_role('admin','manager','office','material_handler','shipping') and created_by = auth.uid());

create policy "office edits intake" on public.po_intake for all to authenticated
  using (public.has_role('admin','manager','office')) with check (public.has_role('admin','manager','office'));
create policy "office edits orders" on public.production_orders for all to authenticated
  using (public.has_role('admin','manager','office')) with check (public.has_role('admin','manager','office'));
create policy "office edits order rolls" on public.order_rolls for all to authenticated
  using (public.has_role('admin','manager','office')) with check (public.has_role('admin','manager','office'));

-- Floor events: anyone signed in can log, only as themselves. Nobody edits history except admins.
create policy "log floor events as yourself" on public.production_events for insert to authenticated
  with check (public.my_role() is not null and created_by = auth.uid());
create policy "admins correct floor events" on public.production_events for update to authenticated
  using (public.has_role('admin')) with check (public.has_role('admin'));
create policy "admins delete floor events" on public.production_events for delete to authenticated
  using (public.has_role('admin'));

create policy "anyone reports a problem" on public.work_orders for insert to authenticated
  with check (public.my_role() is not null);
create policy "maintenance updates work orders" on public.work_orders for update to authenticated
  using (public.has_role('admin','manager','maintenance')) with check (public.has_role('admin','manager','maintenance'));
create policy "maintenance edits PMs" on public.pm_tasks for all to authenticated
  using (public.has_role('admin','manager','maintenance')) with check (public.has_role('admin','manager','maintenance'));
create policy "maintenance edits safety docs" on public.safety_docs for all to authenticated
  using (public.has_role('admin','manager','maintenance')) with check (public.has_role('admin','manager','maintenance'));

create policy "office and shipping edit supplies" on public.consumables for all to authenticated
  using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));
create policy "shipping edits inbound" on public.inbound_loads for all to authenticated
  using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));
create policy "shipping edits shipments" on public.shipments for all to authenticated
  using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));
create policy "shipping edits shipment orders" on public.shipment_orders for all to authenticated
  using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));

-- Profiles: see yourself; managers see everyone; only admins change roles.
alter table public.profiles enable row level security;
create policy "see own profile" on public.profiles for select to authenticated
  using (id = auth.uid() or public.has_role('admin','manager'));
create policy "admins manage profiles" on public.profiles for update to authenticated
  using (public.has_role('admin')) with check (public.has_role('admin'));

-- Training: your own rows; managers read everyone's.
alter table public.training_progress enable row level security;
alter table public.training_quiz enable row level security;
create policy "own training read" on public.training_progress for select to authenticated
  using (user_id = auth.uid() or public.has_role('admin','manager'));
create policy "own training write" on public.training_progress for insert to authenticated
  with check (user_id = auth.uid());
create policy "own training delete" on public.training_progress for delete to authenticated
  using (user_id = auth.uid());
create policy "own quiz read" on public.training_quiz for select to authenticated
  using (user_id = auth.uid() or public.has_role('admin','manager'));
create policy "own quiz write" on public.training_quiz for insert to authenticated
  with check (user_id = auth.uid());
create policy "own quiz update" on public.training_quiz for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- =====================================================================
-- Realtime: dashboard and floor screens update the instant something is logged.
-- =====================================================================
alter publication supabase_realtime add table
  public.production_events, public.master_rolls, public.production_orders,
  public.work_orders, public.shipments, public.po_intake;

-- =====================================================================
-- Starter data (rename anything in the app's Settings tab)
-- =====================================================================
insert into public.machines (id, name, max_width_in, type, shift_target, rated_fpm, sort) values
  ('S1','JJ1',72,'Wide-web rewinder',50,900,1),
  ('S2','JJ2',64,'Duplex',16,500,2),
  ('S3','#41',60,'Score-cut',13,700,3),
  ('S4','WEBCO',98,'Wide-web',32,1000,4),
  ('S5','#63',44,'Narrow-web',18,600,5);

insert into public.bays (id, description) values
  ('A','FR filter grades'),('B','CNA core board'),('C','Cupstock'),('D','Kraft'),('E','Tag & label stock');

insert into public.settings (key, value) values
  ('targets',   '{"weekly":2600,"uptime":85,"trim":4,"changeover":20}'),
  ('lean_goal', '{"dollars":15000}');
