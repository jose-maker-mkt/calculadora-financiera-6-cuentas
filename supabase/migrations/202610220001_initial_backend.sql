-- Store the diagnosis in Supabase and queue a separate Google Sheets sync.
create extension if not exists pgcrypto;

create table if not exists public.financial_diagnoses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  country_code text not null,
  phone text not null,
  international_phone text not null,
  income_amount numeric(14,2) not null check (income_amount > 0),
  currency text not null check (currency in ('PEN','USD')),
  financial_level text not null,
  fx_rate numeric(14,6) not null check (fx_rate > 0),
  fx_date text,
  investment_monthly numeric(14,2) not null check (investment_monthly >= 0),
  investment_monthly_usd numeric(14,2) not null check (investment_monthly_usd >= 0),
  minimum_amount numeric(14,2) not null check (minimum_amount > 0),
  consented_at timestamptz not null default now(),
  consent_version text not null default 'educational-simulation-v1',
  last_pdf_downloaded_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists financial_diagnoses_created_at_idx
  on public.financial_diagnoses (created_at desc);
create index if not exists financial_diagnoses_email_idx
  on public.financial_diagnoses (lower(email));

alter table public.financial_diagnoses enable row level security;
revoke all on public.financial_diagnoses from anon, authenticated;
grant all on public.financial_diagnoses to service_role;

create table if not exists public.sheets_sync_jobs (
  id bigint generated always as identity primary key,
  diagnosis_id uuid not null references public.financial_diagnoses(id) on delete cascade,
  payload jsonb,
  status text not null default 'pending' check (status in ('pending','processing','synced','failed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  synced_at timestamptz
);

create index if not exists sheets_sync_jobs_ready_idx
  on public.sheets_sync_jobs (next_attempt_at, id) where status in ('pending','processing');
alter table public.sheets_sync_jobs enable row level security;
revoke all on public.sheets_sync_jobs from anon, authenticated;
grant all on public.sheets_sync_jobs to service_role;

create or replace function public.submit_financial_diagnosis(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_email text;
  v_currency text;
  v_income numeric;
  v_investment numeric;
  v_fx numeric;
  v_minimum numeric;
begin
  if coalesce((p_data->>'consent')::boolean, false) is not true then
    raise exception 'consent_required' using errcode = '22023';
  end if;
  v_email := lower(trim(coalesce(p_data->>'email','')));
  v_currency := p_data->>'currency';
  v_income := nullif(p_data->>'income','')::numeric;
  v_investment := nullif(p_data->>'investmentMonthly','')::numeric;
  v_fx := nullif(p_data->>'fxRate','')::numeric;
  v_minimum := nullif(p_data->>'minimumAmount','')::numeric;
  if length(v_email) > 254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$'
    or length(trim(coalesce(p_data->>'name',''))) not between 2 and 80
    or v_currency not in ('PEN','USD')
    or v_income is null or v_income <= 0 or v_income > 1000000000
    or v_investment is null or v_investment < 0
    or v_fx is null or v_fx <= 0
    or v_minimum is null or v_minimum <= 0 then
    raise exception 'invalid_registration' using errcode = '22023';
  end if;

  insert into public.financial_diagnoses (
    name,email,country_code,phone,international_phone,income_amount,currency,
    financial_level,fx_rate,fx_date,investment_monthly,investment_monthly_usd,
    minimum_amount,consent_version
  ) values (
    trim(p_data->>'name'),v_email,coalesce(p_data->>'countryCode',''),
    coalesce(p_data->>'phone',''),coalesce(p_data->>'internationalPhone',''),
    v_income,v_currency,coalesce(p_data->>'level',''),v_fx,
    nullif(p_data->>'fxDate',''),v_investment,
    coalesce(nullif(p_data->>'investmentMonthlyUsd','')::numeric,0),
    v_minimum,'educational-simulation-v1'
  ) returning id into v_id;

  insert into public.sheets_sync_jobs (diagnosis_id,payload)
  values (v_id, jsonb_build_object(
    'name',trim(p_data->>'name'),'email',v_email,
    'countryCode',coalesce(p_data->>'countryCode',''),
    'phone',coalesce(p_data->>'phone',''),
    'internationalPhone',coalesce(p_data->>'internationalPhone',''),
    'consent',true,'currency',v_currency,'income',v_income,
    'level',coalesce(p_data->>'level',''),'fxRate',v_fx,
    'fxDate',nullif(p_data->>'fxDate',''),'investmentMonthly',v_investment,
    'investmentMonthlyUsd',coalesce(nullif(p_data->>'investmentMonthlyUsd','')::numeric,0),
    'minimumAmount',v_minimum,'shareWithNestor',false,
    'leadQualified',coalesce((p_data->>'leadQualified')::boolean,false)
  ));
  return jsonb_build_object('registrationId',v_id);
end;
$$;

create or replace function public.record_diagnosis_pdf_download(p_registration_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.financial_diagnoses
     set last_pdf_downloaded_at = now()
   where id = p_registration_id;
  return found;
end;
$$;

create or replace function public.claim_sheets_sync_jobs(p_batch_size integer default 40)
returns table(id bigint, diagnosis_id uuid, payload jsonb, attempts integer)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  with picked as (
    select j.id
      from public.sheets_sync_jobs j
     where (j.status = 'pending' and j.next_attempt_at <= now())
        or (j.status = 'processing' and j.locked_at < now() - interval '5 minutes')
     order by j.id
     for update skip locked
     limit greatest(1,least(coalesce(p_batch_size,40),100))
  )
  update public.sheets_sync_jobs j
     set status='processing', attempts=j.attempts+1, locked_at=now()
    from picked
   where j.id=picked.id
  returning j.id,j.diagnosis_id,j.payload,j.attempts;
end;
$$;

create or replace function public.finish_sheets_sync_job(p_job_id bigint,p_error text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.sheets_sync_jobs
     set status = case when p_error is null then 'synced' when attempts >= 8 then 'failed' else 'pending' end,
         payload = case when p_error is null then null else payload end,
         synced_at = case when p_error is null then now() else null end,
         next_attempt_at = case when p_error is null then next_attempt_at
           else now() + make_interval(mins => least(360, power(2,least(attempts,8))::integer)) end,
         locked_at = null,
         last_error = case when p_error is null then null else left(p_error,500) end
   where id=p_job_id;
end;
$$;

revoke all on function public.submit_financial_diagnosis(jsonb) from public, anon, authenticated;
revoke all on function public.record_diagnosis_pdf_download(uuid) from public, anon, authenticated;
revoke all on function public.claim_sheets_sync_jobs(integer) from public, anon, authenticated;
revoke all on function public.finish_sheets_sync_job(bigint,text) from public, anon, authenticated;
grant execute on function public.submit_financial_diagnosis(jsonb) to service_role;
grant execute on function public.record_diagnosis_pdf_download(uuid) to service_role;
grant execute on function public.claim_sheets_sync_jobs(integer) to service_role;
grant execute on function public.finish_sheets_sync_job(bigint,text) to service_role;
