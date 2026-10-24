-- Additive upgrade: existing entries and RLS policies are preserved.
alter table public.precision_injection_entries
  add column if not exists deleted_at timestamptz,
  add column if not exists sync_operation_ids uuid[] not null default '{}';

create unique index if not exists precision_entries_doctor_date_unique
  on public.precision_injection_entries (doctor_id, date);
create index if not exists precision_entries_incremental_idx
  on public.precision_injection_entries (date, updated_at, id);

create or replace function public.save_incentive_entry_v2(operation jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  entry public.precision_injection_entries%rowtype;
  op_id uuid := (operation->>'operationId')::uuid;
  doctor text := operation->>'doctorId';
  day date := (operation->>'date')::date;
  patch jsonb := coalesce(operation->'changes', '{}'::jsonb);
  expected jsonb := coalesce(operation->'expected', '{}'::jsonb);
  values_now jsonb;
  field text;
  column_name text;
  names jsonb;
  patient_key text;
  patient text;
  additive jsonb := operation->'additive';
begin
  if doctor is null or day is null or op_id is null then raise exception 'Invalid operation'; end if;
  perform pg_advisory_xact_lock(hashtextextended(doctor || '|' || day::text, 0));
  select * into entry from public.precision_injection_entries
    where doctor_id = doctor and date = day for update;
  if found and op_id = any(entry.sync_operation_ids) then
    return to_jsonb(entry) - 'sync_operation_ids' - 'created_by';
  end if;
  if entry.id is null then
    if coalesce((operation->>'remove')::boolean, false) then return null; end if;
    insert into public.precision_injection_entries(doctor_id, date)
      values (doctor, day) returning * into entry;
  end if;
  values_now := jsonb_build_object('count', coalesce(entry.treatment_count, 0),
    'placentaDinaCount', coalesce(entry.placenta_dina_count, 0), 'revenue', coalesce(entry.revenue, 0),
    'lindaRevenue', coalesce(entry.linda_revenue, 0), 'suRevenue', coalesce(entry.su_revenue, 0), 'memo', coalesce(entry.memo, ''));

  if additive is null or additive = 'null'::jsonb then
    for field in select jsonb_object_keys(expected) loop
      if not values_now ? field then raise exception 'Invalid field'; end if;
      if values_now->field is distinct from expected->field
        and (coalesce((operation->>'remove')::boolean, false)
          or values_now->field is distinct from patch->field) then
        raise exception 'SYNC_CONFLICT: % % %', doctor, day, field;
      end if;
    end loop;
    for field in select jsonb_object_keys(patch) loop
      if not values_now ? field or not expected ? field then raise exception 'Invalid patch'; end if;
    end loop;
    values_now := values_now || patch;
  else
    if additive->>'type' not in ('linda', 'su') or (additive->>'amount')::integer <= 0 then
      raise exception 'Invalid additive revenue';
    end if;
    field := case when additive->>'type' = 'su' then 'suRevenue' else 'lindaRevenue' end;
    values_now := jsonb_set(values_now, array[field], to_jsonb((values_now->>field)::integer + (additive->>'amount')::integer));
    patient := trim(coalesce(additive->>'patientName', ''));
    if patient <> '' then
      begin names := entry.memo::jsonb;
      exception when invalid_text_representation then names := '{}'::jsonb; end;
      if jsonb_typeof(names) is distinct from 'object' then names := '{}'::jsonb; end if;
      patient_key := case when additive->>'type' = 'su' then 'suPatients' else 'lindaPatients' end;
      if jsonb_typeof(names->patient_key) is distinct from 'array' then
        names := jsonb_set(names, array[patient_key], '[]'::jsonb);
      end if;
      if not (names->patient_key) @> jsonb_build_array(patient) then
        names := jsonb_set(names, array[patient_key], (names->patient_key) || jsonb_build_array(patient));
      end if;
      values_now := jsonb_set(values_now, '{memo}', to_jsonb(names::text));
    end if;
  end if;

  if coalesce((operation->>'remove')::boolean, false) then
    values_now := jsonb_build_object('count', 0, 'placentaDinaCount', 0, 'revenue', 0,
      'lindaRevenue', 0, 'suRevenue', 0, 'memo', '');
  end if;
  update public.precision_injection_entries set
    treatment_count = (values_now->>'count')::integer,
    placenta_dina_count = (values_now->>'placentaDinaCount')::integer,
    revenue = (values_now->>'revenue')::integer,
    linda_revenue = (values_now->>'lindaRevenue')::integer,
    su_revenue = (values_now->>'suRevenue')::integer,
    memo = values_now->>'memo',
    deleted_at = case when coalesce((operation->>'remove')::boolean, false) then clock_timestamp() else null end,
    updated_at = clock_timestamp(),
    sync_operation_ids = array_append(sync_operation_ids, op_id)
    where id = entry.id returning * into entry;
  return to_jsonb(entry) - 'sync_operation_ids' - 'created_by';
end;
$$;

create or replace function public.save_incentive_setting_v2(change jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  setting public.app_settings%rowtype;
  name text := change->>'key';
  desired jsonb := change->'value';
begin
  if name not in ('doctors', 'procedure_rates', 'finalized_months', 'admin_finalized_months', 'password_hashes') then
    raise exception 'Invalid setting';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('setting|' || name, 0));
  select * into setting from public.app_settings where key = name for update;
  if name in ('finalized_months', 'admin_finalized_months') then
    select coalesce(jsonb_agg(value order by value), '[]'::jsonb) into desired
      from (select distinct value from jsonb_array_elements(coalesce(setting.value, '[]'::jsonb) || desired)) merged;
  elsif setting.value is distinct from change->'expected' and setting.value is distinct from desired and setting.key is not null then
    raise exception 'SYNC_CONFLICT: setting %', name;
  end if;
  insert into public.app_settings(key, value, updated_at) values (name, desired, clock_timestamp())
    on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at
    returning * into setting;
  return jsonb_build_object('key', setting.key, 'value', setting.value);
end;
$$;

revoke all on function public.save_incentive_entry_v2(jsonb) from public;
revoke all on function public.save_incentive_setting_v2(jsonb) from public;
grant execute on function public.save_incentive_entry_v2(jsonb) to anon, authenticated;
grant execute on function public.save_incentive_setting_v2(jsonb) to anon, authenticated;
