-- =====================================================================
-- Paper Dimensions Command Center · CRM tables (run after 01_schema.sql)
-- Office, managers and admins work the CRM. Floor roles can't see it.
-- =====================================================================

create table public.accounts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,          -- must match production_orders.customer
  type       text not null default 'Prospect' check (type in ('Prospect','Customer','Inactive')),
  city       text,
  owner      text,                          -- Barry, Jim ...
  terms      text,
  grades     text,
  since      int,
  notes      text,
  created_at timestamptz not null default now()
);

create table public.contacts (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts on delete cascade,
  name       text not null,
  title      text,
  email      text,
  phone      text
);

create table public.deals (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts on delete cascade,
  what       text not null,
  monthly_value numeric,
  stage      text not null default 'Lead' check (stage in ('Lead','Quoted','Negotiating','Won','Lost')),
  next_step  text,
  due        date,
  owner      text,
  updated_at timestamptz not null default now()
);

create table public.quotes (
  id          text primary key,             -- Q-2041
  account_id  uuid not null references public.accounts on delete cascade,
  grade       text,
  cut_pattern jsonb,                        -- [{"n":16,"w":2.5}]
  masters     int,
  price_per_master numeric,
  lead_days   int,                          -- lead time quoted, from the schedule at the time
  ship_by     date,
  status      text not null default 'Draft' check (status in ('Draft','Sent','Accepted','Lost')),
  sent_at     timestamptz,
  shop_no     text references public.production_orders,  -- set when won
  created_by  uuid default auth.uid() references public.profiles,
  created_at  timestamptz not null default now()
);

create table public.activities (
  id         bigint generated always as identity primary key,
  account_id uuid not null references public.accounts on delete cascade,
  type       text not null check (type in ('Call','Email','Visit','Task','Note')),
  body       text not null,
  due        date,
  done       boolean not null default false,
  created_by uuid default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['accounts','contacts','deals','quotes','activities'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "sales roles read" on public.%I for select to authenticated using (public.has_role(''admin'',''manager'',''office''))', t);
    execute format('create policy "sales roles write" on public.%I for all to authenticated using (public.has_role(''admin'',''manager'',''office'')) with check (public.has_role(''admin'',''manager'',''office''))', t);
  end loop;
end $$;

alter publication supabase_realtime add table public.deals, public.quotes, public.activities;
