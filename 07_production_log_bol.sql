-- =====================================================================
-- Production log (every roll), order log (every step), bills of lading
-- Run after 01-06.
-- =====================================================================

-- Every finished roll, logged at the slitter
alter table public.finished_rolls
  add column if not exists machine_id text references public.machines,
  add column if not exists od_in      numeric,
  add column if not exists weight_lb  numeric,
  add column if not exists splices    int not null default 0,
  add column if not exists qc_status  text not null default 'OK' check (qc_status in ('OK','Hold','Scrap')),
  add column if not exists qc_note    text;
create index if not exists finished_rolls_job on public.finished_rolls (shop_no, made_at);

-- A roll on QC hold can't be staged or shipped
create or replace function public.block_held_rolls() returns trigger
language plpgsql as $$
begin
  if new.status in ('staged','shipped') and new.qc_status <> 'OK' then
    raise exception 'Roll % is on QC hold and cannot be %', new.id, new.status;
  end if;
  return new;
end $$;
create trigger finished_rolls_qc_guard before update on public.finished_rolls
  for each row execute function public.block_held_rolls();

-- Order log: one row per step in an order's life
create table public.order_events (
  id         bigint generated always as identity primary key,
  shop_no    text not null references public.production_orders on delete cascade,
  step       text not null check (step in ('po_received','entered','paper_held','paper_received',
              'production_started','rolls_logged','shipping_booked','bol_created','shipped','invoiced','note')),
  detail     text,
  actor      text not null default 'system',     -- 'system' or the person
  created_by uuid default auth.uid() references public.profiles,
  created_at timestamptz not null default now()
);
create index on public.order_events (shop_no, created_at);

-- Bills of lading
create table public.bills_of_lading (
  id           text primary key,                 -- BOL-K26011
  shipment_id  text references public.shipments,
  release_id   text references public.releases,
  bol_date     date not null default current_date,
  carrier      text,
  scac         text,
  pro_number   text,
  trailer_no   text,
  seal_no      text,
  freight_terms text not null default 'Prepaid' check (freight_terms in ('Prepaid','Collect','Third party')),
  bill_to      text,
  special_instructions text,
  handling_units int,
  packages     int,
  weight_lb    numeric,
  commodity    text default 'Paper, in rolls, slit',
  nmfc         text,
  freight_class text,
  printed_at   timestamptz,
  driver_signed_at timestamptz,
  signed_copy_url text,                          -- photo or scan of the signed BOL
  created_by   uuid default auth.uid() references public.profiles,
  created_at   timestamptz not null default now()
);

-- Ship-from address on paperwork
insert into public.settings (key, value) values ('company', '{"addr":"","phone":""}')
  on conflict (key) do nothing;

-- Security
alter table public.order_events     enable row level security;
alter table public.bills_of_lading  enable row level security;
create policy "staff read order log" on public.order_events for select to authenticated using (public.my_role() is not null);
create policy "staff write order log" on public.order_events for insert to authenticated with check (public.my_role() is not null);
create policy "staff read bols" on public.bills_of_lading for select to authenticated using (public.my_role() is not null);
create policy "office and shipping manage bols" on public.bills_of_lading for all to authenticated
  using (public.has_role('admin','manager','office','shipping')) with check (public.has_role('admin','manager','office','shipping'));
create policy "customer sees own bols" on public.bills_of_lading for select to authenticated
  using (release_id in (select id from public.releases where account_id = public.my_account())
      or shipment_id in (select so.shipment_id from public.shipment_orders so
                         join public.production_orders po on po.shop_no = so.shop_no
                         where po.customer = public.my_account_name()));

alter publication supabase_realtime add table public.order_events, public.bills_of_lading;
