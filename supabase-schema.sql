-- 목포 부부한의원 의료진 인센티브 관리 - 간단 실사용형 Supabase 스키마
-- 원내 전용 앱 기준입니다. Supabase Auth/RLS 없이 anon key로 앱이 직접 동기화합니다.
-- Supabase SQL Editor에서 전체 실행한 뒤, 앱의 관리자 설정에 Project URL과 anon key를 입력하세요.

create extension if not exists pgcrypto;

create table if not exists public.precision_injection_entries (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  doctor_id text not null,
  treatment_count integer not null default 0 check (treatment_count >= 0),
  placenta_dina_count integer not null default 0 check (placenta_dina_count >= 0),
  revenue integer not null default 0 check (revenue >= 0),
  linda_revenue integer not null default 0 check (linda_revenue >= 0),
  su_revenue integer not null default 0 check (su_revenue >= 0),
  memo text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create index if not exists precision_injection_entries_month_idx
on public.precision_injection_entries (date, doctor_id);

-- 간단 실사용형: 원내 전용으로 사용할 예정이므로 RLS를 끕니다.
-- 향후 외부 공개/강한 보안이 필요해지면 Supabase Auth + RLS 방식으로 전환하세요.
alter table public.precision_injection_entries disable row level security;
alter table public.app_settings disable row level security;


-- anon/public key로 브라우저 앱에서 직접 읽고 쓸 수 있도록 권한을 부여합니다.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.precision_injection_entries to anon, authenticated;
grant select, insert, update, delete on public.app_settings to anon, authenticated;
