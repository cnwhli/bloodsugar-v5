# 血糖管家 V5.0 — 动态血糖仪跨平台 App

GPLv3 开源，免费给糖友用。手机（Android / iOS）+ 手表（OPPO Watch X 优先）同包运行。

## 能用的功能（真机验证过）

- **微泰 AiDEX 二代直连**：被动听 BLE 广播（service `0x181F` + Nordic `0x0059`），1 分钟 1 个点，每包含当前+前 2 分钟 3 个点，漏扫自动补洞；分钟序号去重，库里主存 mg/dL 整数
- **后台常驻**：前台服务 + 省电扫描（扫 15 秒停 45 秒）+ 25 分钟看门狗 + 开机自启；退后台照收，悬浮窗/通知实时更新
- **AGP 血糖报告**（对标微泰/硅基/雅培官方 + 2023 国内共识五步法）：7/14/30 天、TIR 五分区、GMI、CV、AGP 全天分位图、低血糖事件清单、高血糖时段分布、每日曲线、CSV 全量导出；核心算法 6 个单测全过（`test/agp_stats_test.dart`）
- **自研手表表盘**：三页（数值/历史曲线/今日统计）+ 手势（左右滑切页、点按刷新/切范围、长按开关监听）+ 抬腕 resumed 刷新 + 心率/步数/运动 + 超限震动；省电 CustomPaint 火花线
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

### 云同步 / 账号：本地单机，换手机数据带不走

`sync_service.dart`、`multi_watch_arch.dart` 的 Supabase 部分全是 `UnimplementedError`。Supabase 的表结构 SQL 在 `supabase_config.dart` 里写好了，但没项目、没 Key、没接 SDK。账号功能依赖它——要做的话顺序是：建 Supabase 项目 → 填 URL/Key → 接 `supabase_flutter` 初始化 → 实现 publish/subscribe → 再做登录页。

### AI 助手：能聊天，RAG 没接

`ai_agent_service.dart` 走用户自己的 Hermes/OpenClaw 网关能问答；`rag_service.dart` 的 pgvector 知识库（embedding/search/ask）全是 `UnimplementedError`，需 OpenAI Key + Supabase pgvector。

## 快速启动

```bash
flutter pub get
flutter run -d android   # 本机无 SDK 时靠 GitHub Actions 出包（push 即构建）
```

## 项目结构

```
lib/
├── domain/bluetooth/cgm_protocol.dart   # CGM 协议层（AiDEX✅ + 6 个⏳骨架）
├── domain/bluetooth/medtronic_cgm_protocol.dart  # 美敦力占位
├── domain/bluetooth/pump_protocol.dart  # 泵协议层（架子+假数据，勿当真）
├── domain/bluetooth/pump_pairing.dart   # 泵配对
├── domain/report/agp.dart               # AGP 统计（纯 Dart，有单测）
├── data/datasource/local_db.dart        # sqflite 本地库（v4：mg/dL整数+分钟序号）
├── services/bg_sync.dart                # 后台→前台通知桥
├── ui/dashboard/  ui/ble/  ui/watch/    # 首页 / 蓝牙+后台服务 / 手表三页表盘
├── ui/report/report_screen.dart         # AGP 报告页
├── ui/community/wechat_group_screen.dart # 糖友微信群（自建社区已下掉）
test/agp_stats_test.dart                 # 6 用例，flutter test 全过
```

## 参考项目（GPLv3 保留出处）

| 项目 | 用了什么 | 许可证 |
|------|----------|--------|
| Juggluco | AiDEX 广播结构（`aidexx/glucose.h`）、硅基/Accu 流程 | GPLv3 |
| DiaBLE | Libre 2/3、Dexcom G7 流程 | GPLv3 |
| xDrip+ | Dexcom G6 握手 | GPLv3 |
| AndroidAPS / OpenAPS | 泵协议框架、FIAST 剂量算法 | GPLv3 / MIT |
