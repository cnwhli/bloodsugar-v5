# 血糖管家 V5.0 — 动态血糖仪跨平台 App

GPLv3 开源，免费给糖友用。手机（Android / iOS）+ 手表（OPPO Watch X 优先）同包运行。

## 能用的功能（真机验证过）

- **微泰 AiDEX 二代直连**：被动听 BLE 广播（service `0x181F` + Nordic `0x0059`），1 分钟 1 个点，每包含当前+前 2 分钟 3 个点，漏扫自动补洞；分钟序号去重，库里主存 mg/dL 整数
- **后台常驻**：前台服务 + 省电扫描（扫 15 秒停 45 秒）+ 25 分钟看门狗 + 开机自启；退后台照收，悬浮窗/通知实时更新
- **AGP 血糖报告**（对标微泰/硅基/雅培官方 + 2023 国内共识五步法）：7/14/30 天、TIR 五分区、GMI、CV、AGP 全天分位图、低血糖事件清单、高血糖时段分布、每日曲线、CSV 全量导出；核心算法 6 个单测全过（`test/agp_stats_test.dart`）
- **自研手表表盘**：三页（数值/历史曲线/今日统计）+ 手势（左右滑切页、点按刷新/切范围、长按开关监听）+ 抬腕 resumed 刷新 + 心率/步数/运动 + 超限震动；省电 CustomPaint 火花线
- **手表硬件直读心率/计步**：原生 `MethodChannel sensors.bloodsugar` 走 `SensorManager`（`TYPE_HEART_RATE` + `TYPE_STEP_COUNTER`，`SENSOR_DELAY_NORMAL` 最低功耗），不经过 Health Connect；国行无 GMS 也能用；直读心率 1 分钟记 1 条、步数 1 小时记 1 条入库（`source=ble`）
- **手表灭屏保活**：手表点监听后同样起前台服务 + 先要电池白名单，灭屏照样收，通知栏看当前值（之前手表裸 `startScan()` 灭屏 1-2 分钟被杀丢数）
- **手机桌面小组件**：原生 `RemoteViews` 深色圆角卡片，大数字颜色（绿/蓝/红）+ 趋势箭头 + 更新于 + 心率步数行（无则隐藏），首页"加到桌面"一键钉；小组件只显示不收数，收数靠前台服务
- **手机↔手表云互通**：Supabase Realtime 秒级双向同步（血糖/vitals/记一笔），一方上传另一方秒级入库+刷新 UI；换设备登录点"从云端恢复"，云端 id（`r/v/t`+本地 id）天然去重不翻倍；key 只存本机安全存储，不进代码不进仓库
- **手表配对码登录**：手表无摄像头，手机云同步页出 6 位配对码（5 分钟有效、一次即焚），手表圆屏大键盘输码即登录同一账号；token 存本机安全存储，下次直接恢复
- **阈值报警**：高 10.0 / 低 3.9 可调，震动/声音/震动+声音四档
- **糖友微信群**：扫码进群 + 加群主 + 一键打开微信（替代自建社区；二维码放 `assets/images/wechat_group.png`，群主号填 `wechat_group_screen.dart` 顶部）
- **半闭环**：只算剂量建议、用户在泵上手动确认；`sendBolus()` 抛 `UnsupportedError`；低血糖<3.9 停建议；单次≤12U、纠正≤6U

## 没做完的功能（诚实清单）

### CGM：只有微泰能直连，其他都是骨架

| 品牌 | 状态 | 差什么 |
|------|------|--------|
| 微泰 AiDEX 二代 | ✅ 广播直读可用 | GATT 历史（发射器只广播当前分钟，关机漏的补不回） |
| Libre 2 | ⏳ 扫得到、连得上、解不出数 | `Libre2.decryptBLE`：AES 解密需先 NFC 扫一次拿传感器 UID（DiaBLE `Libre2.swift decryptBLE` / `Crypto.swift` 待移植） |
| Libre 3 | ⏳ 发现设备，读不到数 | ECDH 证书认证流程（DiaBLE `Libre3.swift CMD_ECDH_START…COMPLETE` 待移植） |
| Dexcom G6 | ⏳ 发现设备，读不到数 | AuthRequest/AuthChallenge 握手，key=`"00<serial>00<serial>"` AES-128（xDrip `AuthChallengeTxMessage` 待移植） |
| Dexcom G7 | ⏳ 同上 | J-PAKE 交换（DiaBLE `DexcomG7.swift` 待移植） |
| 硅基 GS1/GS3 | ⏳ UUID 已对，待真机验证 | FF32 握手序列 + FF31 通知解析（Juggluco `Si3GattCallback` 待移植） |
| Accu-Chek SmartGuide | ⏳ 同上 | 标准 sfloat 解析 + RACP 取历史（Juggluco `AccuGattCallback` 待移植） |
| Medtronic Guardian 4 / Simplera | ❌ 无公开协议 | 私有协议，开源界（xDrip/AndroidAPS）也没直连，只能走 CareLink 云 |

要"支持市面上所有"：上面每个 TODO 都要真机联调，没有设备借不到就做不出来。建议按用户手里有的设备一台一台啃，先啃 Libre 2（NFC+AES，文档最全）。

### 胰岛素泵：只搭了架子

Dana-R / OmniPod / Medtronic 三个类只能`readStatus`返回写死的假数（电量 100%、余量 300U），`sendBolus`按半闭环要求抛错。真机 GATT 读写一律没接。Tandem t:slim X2 还没建类。

### AI 助手：能聊天，RAG 没接

`ai_agent_service.dart` 走用户自己的 Hermes/OpenClaw 网关能问答；`rag_service.dart` 的 pgvector 知识库（embedding/search/ask）全是 `UnimplementedError`，需 OpenAI Key + Supabase pgvector。

### 悬浮窗：国产 ROM 小窗渲染坑，已改全屏方案待验证

`flutter_overlay_window` 传 160×72 小窗时，MagicOS/ColorOS 上整窗空白（`isActive` 还报 true）。已改 `matchParent` 全屏渲染 + 内容右中卡片自己定位（官方 example 同款）+ `positionGravity.auto` + 全屏层 `IgnorePointer` 不挡触摸。待真机验证退桌面后右侧黑底小窗。

### 睡眠/血压/血氧/运动类别：硬件直读拿不到，只能手填

OPPO Watch X 的血氧/睡眠/血压算法在欢太/OHealth 私有 SDK，不走标准 `SensorManager`，第三方拿不到；运动类别系统自识别不开放。现状：心率步数硬件直读 + 记一笔手填 + 曲线。Health Connect 在国行无 GMS 的设备上装不上、欢太也不同步，走不通。

## 快速启动

```bash
flutter pub get
flutter run -d android   # 本机无 SDK 时靠 GitHub Actions 出包（push 即构建）
```

云同步需先在 Supabase 后台 SQL Editor 执行 `supabase_schema.sql`（三表+RLS+Realtime 发布），配对码登录再执行 `supabase_pairing.sql`（配对码表+函数）。App 里：我的页 → 云同步 → 填 URL+anon key（只存本机）→ 登录/注册；手机出 6 位配对码，手表输码登录。

## 项目结构

```
lib/
├── domain/bluetooth/cgm_protocol.dart   # CGM 协议层（AiDEX✅ + 6 个⏳骨架）
├── domain/bluetooth/medtronic_cgm_protocol.dart  # 美敦力占位
├── domain/bluetooth/pump_protocol.dart  # 泵协议层（架子+假数据，勿当真）
├── domain/bluetooth/pump_pairing.dart   # 泵配对
├── domain/report/agp.dart               # AGP 统计（纯 Dart，有单测）
├── data/datasource/local_db.dart        # sqflite 本地库（v8：mg/dL整数+分钟序号+发射器联合去重）
├── services/bg_sync.dart                # 后台→前台通知桥（v3：value|trend|iso|seq|sensorId）
├── services/cloud_sync.dart             # Supabase 云同步（配置/登录/上传/下拉/Realtime/配对码）
├── services/watch_sensors.dart          # 手表硬件直读桥（MethodChannel sensors.bloodsugar）
├── services/phone_widget.dart           # 桌面小组件桥（saveWidgetData+updateWidget+requestPin）
├── ui/dashboard/  ui/ble/  ui/watch/    # 首页 / 蓝牙+后台服务 / 手表三页表盘
├── ui/report/report_screen.dart         # AGP 报告页
├── ui/profile/cloud_sync_screen.dart    # 云同步页（登录/同步/出配对码）
├── ui/profile/pairing_code_screen.dart  # 手表配对码登录页（圆屏大键盘）
├── ui/community/wechat_group_screen.dart # 糖友微信群（自建社区已下掉）
supabase_schema.sql                      # 云同步表结构（后台执行一次）
supabase_pairing.sql                     # 配对码表+函数（后台执行一次）
test/agp_stats_test.dart                 # 6 用例，flutter test 全过
```

## 参考项目（GPLv3 保留出处）

| 项目 | 用了什么 | 许可证 |
|------|----------|--------|
| Juggluco | AiDEX 广播结构（`aidexx/glucose.h`）、硅基/Accu 流程 | GPLv3 |
| DiaBLE | Libre 2/3、Dexcom G7 流程 | GPLv3 |
| xDrip+ | Dexcom G6 握手 | GPLv3 |
| AndroidAPS / OpenAPS | 泵协议框架、FIAST 剂量算法 | GPLv3 / MIT |
