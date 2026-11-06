-- =====================================================================
-- Quoting: price book, priced quotes, automated RFQ intake (run after 01-04)
-- =====================================================================

-- Price book: one row per setting, editable by managers in the app
create table public.price_book (
  key   text primary key,      -- setup, per_master, per_cut, markup_pct, pallet, rolls_per_pallet,
  value numeric not null       -- min_margin_pct, auto_max, followup_1_day, followup_2_day, valid_days
);
insert into public.price_book (key, value) values
  ('setup',85),('per_master',45),('per_cut',1.25),('markup_pct',25),('pallet',28),('rolls_per_pallet',16),
  ('min_margin_pct',22),('auto_max',25000),('followup_1_day',3),('followup_2_day',7),('valid_days',30);

create table public.core_prices (
  core_size text primary key,  -- 3" x .100"
  price     numeric not null
);

-- Customer discounts
alter table public.accounts add column discount_pct numeric not null default 0;

-- Priced quotes
alter table public.quotes
  add column supply      text not null default 'customer' check (supply in ('customer','house')),
  add column core_size   text,
  add column lines       jsonb,          -- [{"item":"Setup","qty":1,"unit":85}]
  add column total       numeric,
  add column margin_pct  numeric,
  add column valid_until date,
  add column auto        boolean not null default false,
  add column rfq_id      uuid,
  add column reminder_sent_at timestamptz,
  add column call_task_at     timestamptz;

-- Quote requests read from the inbox
create table public.rfq_intake (
  id          uuid primary key default gen_random_uuid(),
  received_at timestamptz not null default now(),
  from_email  text,
  subject     text,
  account_id  uuid references public.accounts,
  parsed      jsonb,                      -- grade, cuts, width, masters, core
  confidence  int,
  status      text not null default 'waiting' check (status in ('waiting','sent','review')),
  reason      text,
  quote_id    text references public.quotes
);

alter table public.price_book  enable row level security;
alter table public.core_prices enable row level security;
alter table public.rfq_intake  enable row level security;
create policy "sales read price book" on public.price_book for select to authenticated using (public.has_role('admin','manager','office'));
create policy "managers edit price book" on public.price_book for all to authenticated using (public.has_role('admin','manager')) with check (public.has_role('admin','manager'));
create policy "sales read cores" on public.core_prices for select to authenticated using (public.has_role('admin','manager','office'));
create policy "managers edit cores" on public.core_prices for all to authenticated using (public.has_role('admin','manager')) with check (public.has_role('admin','manager'));
create policy "sales work rfqs" on public.rfq_intake for all to authenticated using (public.has_role('admin','manager','office')) with check (public.has_role('admin','manager','office'));

alter publication supabase_realtime add table public.rfq_intake;
