-- 手表配对码登录（supabase_schema.sql 之后执行，一次即可）
-- 手表没摄像头不能扫码：手机点一下出 6 位数字，手表输码即登录同一账号。
-- 码 5 分钟过期、用一次即删；token 经 SECURITY DEFINER 函数中转，
-- 表本身不开放 anon 直接读写，扫全表也拿不到东西。

create table if not exists cloud_pairing_codes (
  code text primary key,
  access text not null,
  refresh text not null,
  expires_at timestamptz not null,
  created_at timestamptz default now()
);

alter table cloud_pairing_codes enable row level security;
-- 不建任何 policy = anon 直接读写全拒绝，只走下面两个函数。

-- 手机侧：存码（顺手清过期码）。code 碰撞极低，冲突则覆盖。
create or replace function create_pairing_code(
  p_code text, p_access text, p_refresh text
)
returns void
language plpgsql
security definer
as $$
begin
  delete from cloud_pairing_codes where expires_at < now();
  insert into cloud_pairing_codes(code, access, refresh, expires_at)
  values (p_code, p_access, p_refresh, now() + interval '5 minutes')
  on conflict (code) do update set
    access = excluded.access,
    refresh = excluded.refresh,
    expires_at = excluded.expires_at;
end $$;

-- 手表侧：凭码取 token（一次即焚）。码不对/过期返回空行。
create or replace function redeem_pairing_code(p_code text)
returns table (access text, refresh text)
language plpgsql
security definer
as $$
declare
  r record;
begin
  delete from cloud_pairing_codes where expires_at < now();
  select * into r from cloud_pairing_codes where code = p_code;
  if not found then return; end if;
  delete from cloud_pairing_codes where code = p_code;
  access := r.access;
  refresh := r.refresh;
  return next;
end $$;

grant execute on function create_pairing_code(text, text, text) to anon;
grant execute on function redeem_pairing_code(text) to anon;
