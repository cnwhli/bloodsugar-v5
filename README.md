# 血糖管家 BloodSugar — 开源动态血糖管理平台 V5.0

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20WearOS-green.svg)]()
[![CGM](https://img.shields.io/badge/CGM-AiDEX%202%20%E2%9C%85-orange.svg)]()

一款为糖友打造的免费开源 App：手机 × 手表协同，实时血糖、运动健康、云端同步，一套方案全覆盖。

One app for your phone and your watch — real-time glucose, health vitals, and cloud sync, free forever under GPLv3.

---

## 功能 Features

### 📡 CGM 直连 — 微泰 AiDEX 二代 + 硅基 GS1（一键直连）

- 微泰 AiDEX 二代：被动监听 BLE 广播（Service `0x181F` + Nordic `0x0059`），1 分钟 1 个数据点
- **硅基 GS1**：连接型直连（Service `5347` + FF31/FF32），连→订阅→认证→出数全自动，日志一步一报
- 每包携带当前 + 前 2 分钟共 3 个点，漏扫自动补洞，断线不断史
- 分钟序号 + 发射器双重去重，换发射器不丢不断；本地主存 mg/dL 整数
- **连不上自诊断**：从"附近"到"入库"每步失败都写人话日志（无厂家数据/CRC坏包/valid=0/官方App抢连/信号dBm），60秒节流不刷屏
- **前后台不断链**：后台服务在跑时前台只复用不重启扫描；切后台/锁屏照样收，回来自动补列表
- **连接退避**：连不上的设备（硅基握手失败）90秒×失败次数内不再试（最多10分钟），不再每次广播都停扫重连拖累微泰广播收数
- **微泰无数据修复**：短UUID的substring(4,8)崩溃连带丢微泰包，已加固；LT开头是硅基发射器蓝牙名不再误当GS1序列号连
- **硅基断连死循环修复**：握手失败（无FF31/FF32）抛异常计入退避不再假装"已连接"；重连监听单例化，不再并发挤断GATT
- **固定签名**：Release 包用固定 keystore 签名（CI Secrets 注入），包之间可直接覆盖安装，不再报签名不一致

### ⌚ 手表端 — 为 OPPO Watch X 而生

- **自研三页表盘**：实时数值 / 历史曲线 / 今日统计，左右滑动切换
- 手势操作：点按刷新、长按开关监听；抬腕即显数，无等待菊花
- **硬件直读心率与计步**：原生通道直通 `SensorManager`（`TYPE_HEART_RATE` + `TYPE_STEP_COUNTER`），最低功耗采样；国行无谷歌框架照常用，无需 Health Connect 中转
- **灭屏保活**：前台服务 + 电池白名单引导，熄屏、切后台照样收数，通知栏实时可见
- 版面为圆屏优化：血糖数字克制，心率 / 步数 / 运动卡片置顶，一眼即达

### 📱 手机端 — 信息中枢

- **桌面小组件**：原生深色圆角卡片，大数字按血糖区间着色（绿 / 蓝 / 红），趋势箭头 + 更新时间 + 心率步数，一键钉到桌面；只负责显示，采集交给前台服务，省电
- **AGP 专业血糖报告**：对标雅培 / 美敦力 / 硅基官方报告与 2023 中国共识五步法 —— 7/14/30 天、TIR 五分区、GMI、CV、全天分位图、低血糖事件清单、高血糖时段、每日曲线、CSV 全量导出；核心算法 6 个单测全绿
- **阈值报警**：高 10.0 / 低 3.9 可调，震动 / 声音 / 震动+声音
- **AI 健康助手**：对接你自己的 Hermes / OpenClaw 模型网关，血糖数据不出内网
- **对话记一笔**：跟 AI 说"吃了两碗米饭/打了6U/心跳95"，自动识别成饮食/胰岛素/心率记录，确认后直接入库并同步云端，不用再去记录页手填

### ☁️ 云互通 — 手机 × 手表 × 换设备

- Supabase Realtime 秒级双向同步：血糖、身体数据、记一笔（吃饭 / 吃药 / 打针），一方上传、另一方秒级入库并刷新界面
- 手表连发射器，手机实时看心跳、步数、血糖与历史；反之亦然
- 云端 ID 天然去重，换设备登录一键恢复，数据不翻倍、不丢失
- 密钥只存本机安全存储，不进代码、不进仓库；仅使用 `anon` 公钥
- **手表配对码登录**：手表无摄像头，手机出 6 位数字码（5 分钟有效、一次即焚），圆屏大键盘输入即登录同一账号

### 🛡️ 安全半闭环

只给剂量建议，执行永远由你在泵上手动确认 —— `sendBolus()` 直接抛错；低血糖（<3.9）自动停建议；单次 ≤12U、纠正 ≤6U。未经 NMPA 批准，不做全闭环。

### 👥 糖友微信群

扫码进群、一键加群主、直达微信。用现成生态代替自建社区，代码里只留两个可配项：群二维码与群主号。

---

## 待办 Roadmap（诚实版）

### CGM：微泰可用，其余品牌待真机联调

| 品牌 | 现状 | 卡点 |
|------|------|------|
| 微泰 AiDEX 二代 | ✅ 广播直读 | 关机漏包无 GATT 历史可补（硬件极限） |
| Libre 2 | ⏳ 扫到连上、解不出数 | AES 解密需先 NFC 取传感器 UID（待移植 DiaBLE `decryptBLE`） |
| Libre 3 | ⏳ 发现设备、读不到数 | ECDH 证书认证流程待移植 |
| Dexcom G6 | ⏳ 发现设备、读不到数 | AuthRequest/Challenge 握手待移植 |
| Dexcom G7 | ⏳ 同上 | J-PAKE 交换待移植 |
| 硅基 GS1/GS3 | ✅ UUID 已对 + 全机兜底查找 | FF32 握手 + FF31 解析（等真机日志确认挂哪套服务） |
| Accu-Chek SmartGuide | ⏳ 同上 | 标准 sfloat + RACP 取历史待移植 |
| Medtronic Guardian / Simplera | ❌ 无公开协议 | 开源界亦无直连方案，只能走 CareLink 云 |

每一款都需要真机在手才能啃 —— 有设备借得到，就一台一台来。

### 泵：架子已搭，真机读写未接

Dana-R / OmniPod / Medtronic 目前返回占位状态、`sendBolus` 按安全要求抛错；Tandem t:slim X2 尚未建类。

### 睡眠 / 血压 / 血氧 / 运动分类：拿不到，只能手填

手表厂商（欢太 / OHealth）的健康算法是私有 SDK，不走标准传感器接口，第三方无公开 API；运动分类的系统自识别同样不开放。现状：心率步数硬件直读 + 记一笔手填 + 曲线。国行无 GMS 装不上 Health Connect，此路不通。

### 悬浮窗：全屏渲染方案待真机验证

小窗尺寸在部分国产 ROM 上整窗空白，已改全屏渲染 + 内容卡片自定位（官方 example 同款），等真机确认。

### AI 健康助手：聊天可用，对话记一笔待开发

- 聊天问答可用（云端 AI / 本地规则两档），但和你的血糖/饮食/用药数据是脱节的：问"我的血糖怎么样"只带了最近一条血糖，没有曲线上下文
- 说"吃了两碗米饭""打了6U"不会自动记账：AI 回的是文字，没有落库动作
- 下一步：给 AI 接记账工具（`insertTreatment`/`insertVital`），带时间戳确认后写入；对话带上当天曲线摘要

---

## 快速开始 Quick Start

```bash
flutter pub get
flutter run -d android   # 无本地 SDK 时，push 即由 GitHub Actions 出包
```

云同步需在 Supabase 后台 SQL Editor 依次执行（各一次即可）：

1. `supabase_schema.sql` —— 数据三表 + 行级权限 + 实时发布
2. `supabase_pairing.sql` —— 手表配对码表 + 函数

App 内：我的页 → 云同步 → 填 Project URL + anon 公钥（仅存本机）→ 登录；手机生成 6 位配对码，手表输入即同账号。

---

## 项目结构 Structure

```
lib/
├── domain/bluetooth/cgm_protocol.dart        # CGM 协议层（AiDEX ✅ + 6 品牌骨架）
├── domain/bluetooth/medtronic_cgm_protocol.dart
├── domain/bluetooth/pump_protocol.dart       # 泵协议（架子 + 占位数据，勿当真）
├── domain/report/agp.dart                    # AGP 统计（纯 Dart，有单测）
├── data/datasource/local_db.dart             # 本地库 v8（mg/dL 整数 + 序号×发射器联合去重）
├── services/bg_sync.dart                     # 后台→前台通知桥 v3
├── services/cloud_sync.dart                  # 云同步：配置 / 登录 / 上传 / 下拉 / Realtime / 配对码
├── services/watch_sensors.dart               # 手表直读桥（MethodChannel sensors.bloodsugar）
├── services/phone_widget.dart                # 桌面小组件桥
├── ui/dashboard/  ui/ble/  ui/watch/         # 首页 / 蓝牙+后台服务 / 手表三页表盘
├── ui/report/report_screen.dart              # AGP 报告页
├── ui/profile/cloud_sync_screen.dart         # 云同步页
├── ui/profile/pairing_code_screen.dart       # 手表配对码登录（圆屏大键盘）
├── ui/community/wechat_group_screen.dart     # 糖友微信群
supabase_schema.sql / supabase_pairing.sql    # 云端表结构（后台各执行一次）
test/agp_stats_test.dart                      # 6 用例，flutter test 全过
```

## 致谢 Credits（GPLv3 保留出处）

| 项目 | 借鉴 |
|------|------|
| Juggluco | AiDEX 广播结构、硅基 / Accu-Chek 流程 |
| DiaBLE | Libre 2/3、Dexcom G7 流程 |
| xDrip+ | Dexcom G6 握手 |
| AndroidAPS / OpenAPS | 泵协议框架、FIAST 剂量算法 |
