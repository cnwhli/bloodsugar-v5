-- 血糖管家 V5 云同步表结构（Supabase SQL Editor 里一次性执行）
-- 说明：uuid 主键用本机自增 id 拼出来的串，保证手机/手表/云端同一条记录同一个 id，
-- 换设备、双端同时上传都不翻倍。RLS：登录用户只能读写自己的数据。

-- 1. 血糖（含发射器序号+配对码，换发射器不误杀去重）
create table if not exists cloud_readings (
  id text primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  mmol_l double precision not null,
  mg_dl integer,
  trend integer default 0,
  brand text default '',
  source text default 'ble',
  seq integer,
  sensor_id text default '',
  measured_at timestamptz not null,
  created_at timestamptz default now()
);
create index if not exists idx_cloud_readings_user_time
  on cloud_readings(user_id, measured_at desc);

-- 2. 身体指标（心率/血氧/血压/睡眠/步数/体重/运动，和本机 vitals 表 kind 对齐）
-- kind: heart_rate / resting_hr / spo2 / bp / sleep / steps / weight / workout / calories
create table if not exists cloud_vitals (
  id text primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  kind text not null,
  value1 double precision,
  value2 double precision,
  unit text default '',
  source text default 'manual',
  device text default '',
  measured_at timestamptz not null,
  created_at timestamptz default now()
);
create index if not exists idx_cloud_vitals_user_kind_time
  on cloud_vitals(user_id, kind, measured_at desc);

-- 3. 用药/饮食/运动记录（和本机 treatments 表 type 对齐）
-- type: insulin / medication / food / exercise / note
create table if not exists cloud_treatments (
  id text primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  type text not null,
  detail text default '',
  amount double precision,
  unit text default '',
  extra text default '',
  measured_at timestamptz not null,
  created_at timestamptz default now()
);
create index if not exists idx_cloud_treatments_user_time
  on cloud_treatments(user_id, measured_at desc);

-- 4. RLS（行级安全：只能看自己、只能写自己）
alter table cloud_readings enable row level security;
alter table cloud_vitals enable row level security;
alter table cloud_treatments enable row level security;

drop policy if exists "own_readings_all" on cloud_readings;
create policy "own_readings_all" on cloud_readings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own_vitals_all" on cloud_vitals;
create policy "own_vitals_all" on cloud_vitals
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own_treatments_all" on cloud_treatments;
create policy "own_treatments_all" on cloud_treatments
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 5. Realtime（手机/手表互通靠它：一方上传，另一方秒级收到）
-- Supabase 后台 → Database → Replication，把这三张表加进 supabase_realtime 发布即可。
-- SQL 方式（有权限才跑得动，报错就去后台点）：
-- alter publication supabase_realtime add table cloud_readings;
-- alter publication supabase_realtime add table cloud_vitals;
-- alter publication supabase_realtime add table cloud_treatments;
