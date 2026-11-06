-- =====================================================================
-- Inventory ledger + finished goods + QuickBooks sync (run after 01-03)
-- Every scan writes one ledger row. A Supabase Edge Function reads the
-- rows marked qb_status = 'pending' and posts them to QuickBooks Online.
-- =====================================================================

-- Finished rolls, one row per printed label (job-001, job-002 ...)
create table public.finished_rolls (
  id         text primary key,                 -- 51219-001 (the barcode on the label)
  shop_no    text not null references public.production_orders,
  parent_roll text references public.master_rolls,
  width_in   numeric,
  length_ft  int,
  status     text not null default 'made' check (status in ('made','staged','shipped','scrapped')),
  shipment_id text references public.shipments,
  made_by    uuid default auth.uid() references public.profiles,
  made_at    timestamptz not null default now()
);

-- One row for every inventory movement. Never edited, only added to.
create table public.inventory_ledger (
  id         bigint generated always as identity primary key,
  event      text not null check (event in
             ('receive','move','pull','consume','produce','ship','count_adjust','receive_supplies')),
  roll_id    text,                              -- master roll, when it's a roll
  finished_roll_id text,
  shop_no    text,
  grade      text,
  qty        numeric not null default 0,        -- + in, - out
  unit       text not null default 'ft',
  from_loc   text,
  to_loc     text,
  customer_owned boolean not null default false,
  reason     text,
  -- QuickBooks
  qb_status  text not null default 'pending'
             check (qb_status in ('pending','sent','skipped','error')),
  qb_txn_type text,                              -- InventoryAdjustment, Invoice, Bill
  qb_txn_id  text,
  qb_error   text,
  created_by uuid not null default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);
create index on public.inventory_ledger (qb_status) where qb_status = 'pending';

-- Moves, pulls and customer-owned paper never touch QuickBooks
create or replace function public.ledger_set_qb_status() returns trigger
language plpgsql as $$
begin
  if new.customer_owned or new.event in ('move','pull') then
    new.qb_status := 'skipped';
  end if;
  return new;
end $$;
create trigger ledger_qb_status before insert on public.inventory_ledger
  for each row execute function public.ledger_set_qb_status();

-- Grade -> QuickBooks item
create table public.qb_item_map (
  grade       text primary key,
  qb_item_id  text not null,                     -- QuickBooks Item Id
  qb_item_name text,
  kind        text not null default 'raw' check (kind in ('raw','finished','service'))
);

-- QuickBooks connection. Tokens are only readable by the Edge Function
-- (service role). No policy = no access from the app.
create table public.qb_connection (
  id            int primary key default 1 check (id = 1),
  realm_id      text,
  access_token  text,
  refresh_token text,
  expires_at    timestamptz,
  last_pull_at  timestamptz,
  last_push_at  timestamptz
);

create table public.qb_sync_log (
  id         bigint generated always as identity primary key,
  direction  text not null check (direction in ('push','pull')),
  what       text,
  ok         boolean not null,
  detail     text,
  created_at timestamptz not null default now()
);

-- Security
alter table public.finished_rolls   enable row level security;
alter table public.inventory_ledger enable row level security;
alter table public.qb_item_map      enable row level security;
alter table public.qb_connection    enable row level security;   -- no policies on purpose
alter table public.qb_sync_log      enable row level security;

create policy "signed-in read finished rolls" on public.finished_rolls for select to authenticated using (public.my_role() is not null);
create policy "floor and shipping log finished rolls" on public.finished_rolls for insert to authenticated
  with check (public.has_role('admin','manager','office','operator','shipping'));
create policy "shipping updates finished rolls" on public.finished_rolls for update to authenticated
  using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));

create policy "signed-in read ledger" on public.inventory_ledger for select to authenticated using (public.my_role() is not null);
create policy "scan as yourself" on public.inventory_ledger for insert to authenticated
  with check (public.my_role() is not null and created_by = auth.uid());

create policy "office reads item map" on public.qb_item_map for select to authenticated using (public.has_role('admin','manager','office'));
create policy "admins edit item map" on public.qb_item_map for all to authenticated using (public.has_role('admin')) with check (public.has_role('admin'));
create policy "office reads sync log" on public.qb_sync_log for select to authenticated using (public.has_role('admin','manager','office'));

alter publication supabase_realtime add table public.inventory_ledger, public.finished_rolls;

-- Live on-hand by grade (what the system says), to compare with QuickBooks
create view public.on_hand_by_grade with (security_invoker = true) as
select grade,
  count(*) filter (where owner not ilike '%customer%') as own_masters,
  count(*) filter (where owner ilike '%customer%')     as customer_masters,
  sum(footage) filter (where owner not ilike '%customer%') as own_footage
from public.master_rolls
where status in ('in_rack','held','staged')
group by grade;
