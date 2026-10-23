-- Make registration retries safe after a lost or timed-out response.
alter table public.financial_diagnoses
  add column if not exists request_id uuid;

create unique index if not exists financial_diagnoses_request_id_uidx
  on public.financial_diagnoses (request_id)
  where request_id is not null;

create or replace function public.submit_financial_diagnosis(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_request_id uuid;
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

  v_request_id := nullif(p_data->>'requestId','')::uuid;
  if v_request_id is not null then
    perform pg_advisory_xact_lock(hashtextextended(v_request_id::text, 0));
    select id into v_id
      from public.financial_diagnoses
     where request_id = v_request_id;
    if v_id is not null then
      return jsonb_build_object('registrationId',v_id);
    end if;
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
    request_id,name,email,country_code,phone,international_phone,income_amount,currency,
    financial_level,fx_rate,fx_date,investment_monthly,investment_monthly_usd,
    minimum_amount,consent_version
  ) values (
    v_request_id,trim(p_data->>'name'),v_email,coalesce(p_data->>'countryCode',''),
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
