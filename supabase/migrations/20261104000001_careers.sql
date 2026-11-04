-- Bravo careers: jobs and applications
-- Public site reads published jobs and inserts applications (plus a CV upload).
-- Admins (auth users whose email is on the allowlist) manage jobs and applications at /careers-admin.html.

create extension if not exists pgcrypto;

-- ---------- admins ----------
-- Who is allowed into the admin. Add an email here, then that person signs in with a magic link.
create table admin_allowlist (
  email text primary key,
  full_name text,
  added_at timestamptz not null default now()
);

-- One row per auth user who is an admin. Filled automatically from the allowlist.
create table admin_users (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text,
  created_at timestamptz not null default now()
);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admin_users where id = auth.uid())
$$;
grant execute on function is_admin() to anon, authenticated;

-- New auth user: if their email is allowlisted, make them an admin.
create or replace function handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into admin_users (id, email, full_name)
  select new.id, new.email, a.full_name
  from admin_allowlist a
  where lower(a.email) = lower(new.email)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

-- Email allowlisted after the person already has an auth account: make them an admin now.
create or replace function handle_allowlist_insert() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  insert into admin_users (id, email, full_name)
  select u.id, u.email, new.full_name
  from auth.users u
  where lower(u.email) = lower(new.email)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_allowlist_insert
  after insert on admin_allowlist
  for each row execute function handle_allowlist_insert();

-- Removing an email from the allowlist removes admin access.
create or replace function handle_allowlist_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from admin_users where lower(email) = lower(old.email);
  return old;
end $$;
create trigger on_allowlist_delete
  after delete on admin_allowlist
  for each row execute function handle_allowlist_delete();

-- ---------- jobs ----------
create sequence job_ref_seq start 1042;

create table jobs (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default 'BR-' || nextval('job_ref_seq'),
  title text not null,
  area text not null check (area in ('Tax', 'Accounting', 'Bookkeeping', 'Support')),
  level text not null check (level in ('Junior', 'Intermediate', 'Senior')),
  setup text not null,                       -- Work from home / Hybrid, Quezon City / Quezon City office
  client text,                               -- "Australian accounting firm, Brisbane"
  summary text,
  duties text[] not null default '{}',
  requirements text[] not null default '{}',
  software text,
  is_new boolean not null default false,
  status text not null default 'draft' check (status in ('draft', 'published', 'closed')),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on jobs (status, published_at desc);

create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger jobs_touch before update on jobs for each row execute function touch_updated_at();

-- Stamp published_at the first time a job is published.
create or replace function stamp_published_at() returns trigger language plpgsql as $$
begin
  if new.status = 'published' and new.published_at is null then new.published_at = now(); end if;
  return new;
end $$;
create trigger jobs_publish before insert or update on jobs for each row execute function stamp_published_at();

-- ---------- applications ----------
create table applications (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references jobs(id) on delete set null,   -- null = registered interest
  job_ref text,                                          -- snapshot, survives job deletion
  job_title text,
  first_name text not null,
  last_name text not null,
  email text not null,
  phone text,
  au_experience text,
  link text,
  message text,
  cv_path text,                                          -- storage path in private bucket "cvs"
  status text not null default 'new' check (status in ('new', 'reviewing', 'shortlisted', 'interview', 'offer', 'hired', 'declined')),
  notes text,
  source text not null default 'careers_page',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on applications (status, created_at desc);
create index on applications (job_id);
create trigger applications_touch before update on applications for each row execute function touch_updated_at();

-- Anon cannot read jobs that are not published, so policies use this helper.
create or replace function job_is_open(jid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from jobs where id = jid and status = 'published')
$$;
grant execute on function job_is_open(uuid) to anon, authenticated;

-- ---------- views ----------
create view public_jobs with (security_invoker = true) as
  select id, ref, title, area, level, setup, client, summary, duties, requirements, software, is_new, published_at
  from jobs
  where status = 'published';
grant select on public_jobs to anon, authenticated;

create view job_application_counts with (security_invoker = true) as
  select job_id, count(*)::int as total, count(*) filter (where status = 'new')::int as new_count
  from applications
  where job_id is not null
  group by job_id;
grant select on job_application_counts to authenticated;

-- ---------- row level security ----------
alter table admin_allowlist enable row level security;
alter table admin_users enable row level security;
alter table jobs enable row level security;
alter table applications enable row level security;

-- Anyone can read published jobs (the public_jobs view runs as the caller).
create policy "public read published jobs" on jobs for select to anon, authenticated using (status = 'published' or is_admin());
create policy "admin insert jobs" on jobs for insert to authenticated with check (is_admin());
create policy "admin update jobs" on jobs for update to authenticated using (is_admin()) with check (is_admin());
create policy "admin delete jobs" on jobs for delete to authenticated using (is_admin());

-- Anyone can apply for an open job or register interest; only admins can read.
create policy "public insert application" on applications for insert to anon, authenticated with check (job_id is null or job_is_open(job_id));
create policy "admin read applications" on applications for select to authenticated using (is_admin());
create policy "admin update applications" on applications for update to authenticated using (is_admin()) with check (is_admin());
create policy "admin delete applications" on applications for delete to authenticated using (is_admin());

create policy "admin read admins" on admin_users for select to authenticated using (is_admin());
create policy "admin read allowlist" on admin_allowlist for select to authenticated using (is_admin());
create policy "admin add allowlist" on admin_allowlist for insert to authenticated with check (is_admin());
create policy "admin remove allowlist" on admin_allowlist for delete to authenticated using (is_admin() and lower(email) <> lower((select email from admin_users where id = auth.uid())));

-- ---------- CV storage (private bucket) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cvs', 'cvs', false, 10485760, array['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do nothing;

create policy "public upload cv" on storage.objects for insert to anon, authenticated with check (bucket_id = 'cvs');
create policy "admin read cv" on storage.objects for select to authenticated using (bucket_id = 'cvs' and is_admin());
create policy "admin delete cv" on storage.objects for delete to authenticated using (bucket_id = 'cvs' and is_admin());

-- ---------- first admin ----------
insert into admin_allowlist (email, full_name) values ('benjamin@55knots.com.au', 'Ben Williams');
