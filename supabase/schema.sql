-- 3D Prints: Supabase schema
-- Run the whole file once in the SQL Editor (New query, paste, Run).
-- Safe to run again: it never drops data.

-- ---------- tables ----------
create table if not exists public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Workshop',
  code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.household_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  household_id uuid not null references public.households(id) on delete cascade,
  email text,
  joined_at timestamptz not null default now()
);
create index if not exists household_members_hh on public.household_members(household_id);

-- household of the signed-in user
create or replace function public.current_household()
returns uuid language sql stable security definer set search_path = public as $$
  select household_id from public.household_members where user_id = auth.uid()
$$;

create table if not exists public.household_settings (
  household_id uuid primary key references public.households(id) on delete cascade default public.current_household(),
  currency text not null default 'PLN',
  watts numeric not null default 90,
  kwh numeric not null default 1.29
);

create table if not exists public.filaments (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade default public.current_household(),
  brand text not null default '',
  material text not null default 'PLA',
  color text not null default '',
  hex text not null default '#8E9188',
  price_per_kg numeric not null default 0,
  grams numeric not null default 0,
  capacity numeric not null default 1000,
  notes text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists filaments_hh on public.filaments(household_id);

create table if not exists public.models (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade default public.current_household(),
  name text not null default '',
  link text not null default '',
  image text not null default '',
  minutes integer not null default 0,
  description text not null default '',
  list text not null default 'backlog' check (list in ('queue', 'backlog')),
  done boolean not null default false,
  deducted boolean not null default false,
  done_at timestamptz,
  sort_order integer not null default 0,
  uses jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists models_hh on public.models(household_id);

-- ---------- row level security: each user sees only their own household ----------
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_settings enable row level security;
alter table public.filaments enable row level security;
alter table public.models enable row level security;

drop policy if exists "own household" on public.households;
create policy "own household" on public.households
  for select to authenticated using (id = public.current_household());

drop policy if exists "same household" on public.household_members;
create policy "same household" on public.household_members
  for select to authenticated using (household_id = public.current_household());

drop policy if exists "own settings" on public.household_settings;
create policy "own settings" on public.household_settings
  for all to authenticated using (household_id = public.current_household()) with check (household_id = public.current_household());

drop policy if exists "own filaments" on public.filaments;
create policy "own filaments" on public.filaments
  for all to authenticated using (household_id = public.current_household()) with check (household_id = public.current_household());

drop policy if exists "own models" on public.models;
create policy "own models" on public.models
  for all to authenticated using (household_id = public.current_household()) with check (household_id = public.current_household());

-- ---------- functions called by the app ----------
create or replace function public.new_code()
returns text language sql volatile as $$
  select upper(substr(translate(md5(random()::text || clock_timestamp()::text), '01', ''), 1, 8))
$$;

create or replace function public.create_household(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  insert into households(name, code) values (coalesce(nullif(trim(p_name), ''), 'Workshop'), new_code()) returning id into v_id;
  insert into household_members(user_id, household_id, email)
    values (auth.uid(), v_id, auth.jwt() ->> 'email')
    on conflict (user_id) do update set household_id = excluded.household_id, joined_at = now();
  insert into household_settings(household_id) values (v_id) on conflict do nothing;
  return v_id;
end $$;

create or replace function public.join_household(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN'; end if;
  select id into v_id from households where code = upper(trim(p_code));
  if v_id is null then raise exception 'BAD_CODE'; end if;
  insert into household_members(user_id, household_id, email)
    values (auth.uid(), v_id, auth.jwt() ->> 'email')
    on conflict (user_id) do update set household_id = excluded.household_id, joined_at = now();
  return v_id;
end $$;

create or replace function public.new_household_code()
returns text language plpgsql security definer set search_path = public as $$
declare v_code text := new_code();
begin
  update households set code = v_code where id = current_household();
  if not found then raise exception 'NO_HOUSEHOLD'; end if;
  return v_code;
end $$;

create or replace function public.rename_household(p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update households set name = coalesce(nullif(trim(p_name), ''), name) where id = current_household();
end $$;

-- marks a model as printed (or undoes it) and subtracts or returns its grams on the spools
create or replace function public.mark_printed(p_model uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m models; u jsonb;
begin
  select * into m from models where id = p_model and household_id = current_household() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_done and not m.done then
    if not m.deducted then
      for u in select * from jsonb_array_elements(m.uses) loop
        update filaments set grams = greatest(0, grams - coalesce((u ->> 'grams')::numeric, 0))
          where id::text = u ->> 'fid' and household_id = m.household_id;
      end loop;
    end if;
    update models set done = true, deducted = true, done_at = now() where id = p_model;
  elsif not p_done and m.done then
    if m.deducted then
      for u in select * from jsonb_array_elements(m.uses) loop
        update filaments set grams = grams + coalesce((u ->> 'grams')::numeric, 0)
          where id::text = u ->> 'fid' and household_id = m.household_id;
      end loop;
    end if;
    update models set done = false, deducted = false, done_at = null where id = p_model;
  end if;
end $$;

revoke execute on function public.create_household(text), public.join_household(text), public.new_household_code(),
  public.rename_household(text), public.mark_printed(uuid, boolean) from anon, public;
grant execute on function public.create_household(text), public.join_household(text), public.new_household_code(),
  public.rename_household(text), public.mark_printed(uuid, boolean), public.current_household() to authenticated;

-- ---------- realtime: other household members see changes right away ----------
do $$
declare t text;
begin
  foreach t in array array['filaments', 'models', 'household_settings'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- model photos ----------
insert into storage.buckets (id, name, public) values ('model-images', 'model-images', true)
  on conflict (id) do update set public = true;

drop policy if exists "upload own photos" on storage.objects;
create policy "upload own photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'model-images' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "delete own photos" on storage.objects;
create policy "delete own photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'model-images' and (storage.foldername(name))[1] = auth.uid()::text);
