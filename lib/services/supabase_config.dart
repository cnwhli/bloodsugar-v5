/// Supabase 免费后端配置
/// 免费额度：500 用户 / 1GB 存储 / 500MB 数据库 / 实时同步
/// 注册地址：https://supabase.com (免费创建项目)

class SupabaseConfig {
  static const String url = 'https://YOUR_PROJECT.supabase.co';
  static const String anonKey = 'YOUR_ANON_KEY';

  /// 数据表结构
  static const String usersTable = 'users';
  static const String glucoseReadingsTable = 'glucose_readings';
  static const String communityPostsTable = 'community_posts';
  static const String familyLinksTable = 'family_links';
}

/// SQL 初始化脚本（在 Supabase SQL Editor 执行）
const String supabaseInitSql = '''
-- 用户表
create table users (
  id uuid primary key default auth.uid(),
  phone text unique,
  name text,
  age int,
  diabetes_type text check (diabetes_type in ('T1DM','T2DM','GDM','pre')),
  target_low float default 3.9,
  target_high float default 10.0,
  created_at timestamptz default now()
);

-- 血糖读数表（时序数据）
create table glucose_readings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  value_mmol_l float not null,
  value_mg_dl float generated always as (round(value_mmol_l * 18.0182, 1)) stored,
  trend int default 0,
  brand text,
  source text check (source in ('ble','manual','csv')),
  notes text,
  created_at timestamptz default now()
);
create index idx_glucose_user_time on glucose_readings(user_id, created_at desc);

-- 社区动态
create table community_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id),
  content text not null,
  likes int default 0,
  created_at timestamptz default now()
);

-- 家庭共享
create table family_links (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references users(id),
  member_id uuid references users(id),
  role text check (role in ('parent','child','doctor')),
  created_at timestamptz default now()
);

-- 启用 RLS
alter table users enable row level security;
alter table glucose_readings enable row level security;
alter table community_posts enable row level security;
alter table family_links enable row level security;

-- RLS 策略：用户只能看自己的数据
create policy "Users can see own readings" on glucose_readings
  for select using (auth.uid() = user_id);
create policy "Users can insert own readings" on glucose_readings
  for insert with check (auth.uid() = user_id);
''';
