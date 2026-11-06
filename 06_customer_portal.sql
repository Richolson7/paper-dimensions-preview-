-- =====================================================================
-- Customer portal (run after 01-05)
-- Customers log in to the same app but only ever see their own account:
-- their finished rolls, their paper, their orders, their releases.
-- Run PART 1 by itself first, then PART 2 (Postgres needs the new role committed).
-- =====================================================================

-- ---------- PART 1 ----------
alter type public.app_role add value if not exists 'customer';

-- ---------- PART 2 ----------
alter table public.profiles add column if not exists account_id uuid references public.accounts;

-- Staff check: customers are NOT staff. Every existing staff policy uses my_role(),
-- so making it return null for customers locks them out of everything internal at once.
create or replace function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles
  where id = auth.uid() and active and role::text <> 'customer'
$$;

create or replace function public.my_account() returns uuid
language sql stable security definer set search_path = public as $$
  select account_id from public.profiles
  where id = auth.uid() and active and role::text = 'customer'
$$;

create or replace function public.my_account_name() returns text
language sql stable security definer set search_path = public as $$
  select a.name from public.accounts a where a.id = public.my_account()
$$;

-- Ownership columns so customer rows are matched by id, not by name text
alter table public.master_rolls add column if not exists account_id uuid references public.accounts;

-- The customer's part numbers and the targets they set
create table public.customer_items (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts on delete cascade,
  part_no     text not null,               -- their part number, e.g. LT-25-300
  description text,
  grade       text,
  width_in    numeric,
  core_size   text,
  min_rolls   int not null default 0,      -- customer sets; alert when below
  rolls_per_week int,
  unique (account_id, part_no)
);
alter table public.finished_rolls add column if not exists customer_item_id uuid references public.customer_items;

-- Dock time slots
create table public.release_windows (
  id        bigint generated always as identity primary key,
  starts_at timestamptz not null,
  ends_at   timestamptz not null,
  kind      text not null check (kind in ('pickup','delivery')),
  capacity_rolls int not null,
  cutoff_hours  int not null default 24
);

create table public.releases (
  id          text primary key,             -- R-504
  account_id  uuid not null references public.accounts,
  customer_item_id uuid not null references public.customer_items,
  qty_rolls   int not null check (qty_rolls > 0),
  window_id   bigint not null references public.release_windows,
  customer_ref text,                         -- their release / PO number
  status      text not null default 'Requested'
              check (status in ('Requested','Confirmed','Needs review','Staged','Shipped','Cancelled')),
  requested_by uuid default auth.uid() references public.profiles,
  created_at  timestamptz not null default now()
);

create table public.standing_releases (
  id          bigint generated always as identity primary key,
  account_id  uuid not null references public.accounts,
  customer_item_id uuid not null references public.customer_items,
  qty_rolls   int not null,
  rule        text not null,                 -- 'weekly:tue:pickup', 'biweekly:fri:delivery'
  active      boolean not null default true
);

-- Security
alter table public.customer_items    enable row level security;
alter table public.release_windows   enable row level security;
alter table public.releases          enable row level security;
alter table public.standing_releases enable row level security;

-- Staff: full read, shipping/office/managers manage
create policy "staff read items"     on public.customer_items    for select to authenticated using (public.my_role() is not null);
create policy "staff read windows"   on public.release_windows   for select to authenticated using (public.my_role() is not null);
create policy "staff read releases"  on public.releases          for select to authenticated using (public.my_role() is not null);
create policy "staff read standing"  on public.standing_releases for select to authenticated using (public.my_role() is not null);
create policy "staff manage items"   on public.customer_items    for all to authenticated using (public.has_role('admin','manager','office')) with check (public.has_role('admin','manager','office'));
create policy "staff manage windows" on public.release_windows   for all to authenticated using (public.has_role('admin','manager','shipping')) with check (public.has_role('admin','manager','shipping'));
create policy "staff manage releases" on public.releases         for update to authenticated using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));
create policy "staff manage standing" on public.standing_releases for all to authenticated using (public.has_role('admin','manager','office')) with check (public.has_role('admin','manager','office'));

-- Customers: their own account only
create policy "customer sees own items"   on public.customer_items for select to authenticated using (account_id = public.my_account());
create policy "customer sets own minimums" on public.customer_items for update to authenticated using (account_id = public.my_account()) with check (account_id = public.my_account());
create policy "customer sees windows"     on public.release_windows for select to authenticated using (public.my_account() is not null);
create policy "customer sees own releases" on public.releases for select to authenticated using (account_id = public.my_account());
create policy "customer requests releases" on public.releases for insert to authenticated
  with check (account_id = public.my_account() and status = 'Requested' and requested_by = auth.uid());
create policy "customer cancels own release" on public.releases for update to authenticated
  using (account_id = public.my_account() and status in ('Requested','Confirmed'))
  with check (account_id = public.my_account() and status = 'Cancelled');
create policy "customer sees own standing" on public.standing_releases for select to authenticated using (account_id = public.my_account());
create policy "customer toggles own standing" on public.standing_releases for update to authenticated using (account_id = public.my_account()) with check (account_id = public.my_account());

-- Customers read their own orders, rolls and paper (and nothing else)
create policy "customer sees own orders" on public.production_orders for select to authenticated
  using (customer = public.my_account_name());
create policy "customer sees own finished rolls" on public.finished_rolls for select to authenticated
  using (shop_no in (select shop_no from public.production_orders where customer = public.my_account_name()));
create policy "customer sees own paper" on public.master_rolls for select to authenticated
  using (account_id = public.my_account());
create policy "customer sees own account" on public.accounts for select to authenticated
  using (id = public.my_account());

-- Auto-confirm: a release confirms itself when the rolls are there and the slot has room.
create or replace function public.confirm_release() returns trigger
language plpgsql security definer set search_path = public as $$
declare on_hand int; booked int; slot_used int; cap int;
begin
  select count(*) into on_hand from public.finished_rolls
    where customer_item_id = new.customer_item_id and status in ('made','staged');
  select coalesce(sum(qty_rolls),0) into booked from public.releases
    where customer_item_id = new.customer_item_id and status in ('Confirmed','Staged');
  select coalesce(sum(qty_rolls),0) into slot_used from public.releases
    where window_id = new.window_id and status in ('Confirmed','Staged');
  select capacity_rolls into cap from public.release_windows where id = new.window_id;
  if new.qty_rolls <= on_hand - booked and new.qty_rolls <= cap - slot_used then
    new.status := 'Confirmed';
  else
    new.status := 'Needs review';
  end if;
  return new;
end $$;
create trigger releases_auto_confirm before insert on public.releases
  for each row execute function public.confirm_release();

alter publication supabase_realtime add table public.releases, public.customer_items;
