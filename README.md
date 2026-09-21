# BloodSugarApp V5.0 — 动态血糖仪跨平台 App

## 快速启动

```bash
# 1. 安装 Flutter SDK (需要网络)
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor

# 2. 安装依赖
cd BloodSugarApp-v5
flutter pub get

# 3. 运行 Android
flutter run -d android

# 4. 运行 iOS
flutter run -d ios
```

## 项目结构

```
lib/
├── domain/bluetooth/
│   ├── cgm_protocol.dart      # 多品牌 BLE 协议层（Libre 2/3, Dexcom G6/G7, Medtronic）
│   ├── pump_protocol.dart     # 胰岛素泵协议层（Dana-R, OmniPod, Medtronic）+ 半闭环算法
│   ├── medtronic_cgm_protocol.dart  # Medtronic Guardian 4/Simplera 协议
│   └── pump_pairing.dart      # 泵配对 + 密钥管理
├── data/datasource/
│   └── local_db.dart          # drift SQLite 本地数据库
├── services/
│   ├── supabase_config.dart   # Supabase 免费后端配置
│   ├── sync_service.dart      # Supabase Realtime 多端同步
│   └── rag_service.dart       # RAG AI 健康助手（pgvector + Embeddings + LLM）
├── ui/
│   ├── dashboard/dashboard_screen.dart  # 首页仪表盘（圆环 + 统计 + 快捷操作）
│   ├── ble/
│   │   ├── ble_scanner_screen.dart      # BLE 扫描 + 连接 + 实时日志
│   │   ├── dose_confirmation_screen.dart # 半闭环剂量确认弹窗
│   │   └── manual_bolus_screen.dart     # 手动给药指令 + 安全检查
│   ├── chat/chat_screen.dart            # AI 健康助手（占位）
│   ├── profile/profile_screen.dart      # 个人中心
│   ├── community/community_feed_screen.dart # 糖友社区
│   └── watch/
│       ├── multi_watch_arch.dart        # 多品牌手表架构 + 统一数据模型 + CGM 品牌管理 + 屏幕形状自适应
│       ├── watch_app.dart               # 手表入口 + 预警服务
│       ├── watch_glucose_page.dart      # 手表血糖页面 + 预警震动 + 圆形/方形自适应
│       ├── watch_glucose_tile.dart      # 手表端血糖展示组件
│       ├── apple/
│       │   └── apple_watch_face.dart    # Apple Watch 表盘（ClockKit Complication）
│       ├── oppo/
│       │   └── oppo_watch_face.dart     # OPPO Watch 表盘（Flutter Wear）
│       ├── samsung/
│       │   └── samsung_watch_face.dart  # Samsung 表盘（Wear OS + Tizen）
│       └── huawei/
│           └── huawei_watch_face.dart   # 华为表盘（HarmonyOS ArkTS 参考）
```

## 支持的设备

### CGM 血糖仪
| 品牌 | 型号 | 状态 |
|------|------|------|
| Abbott Libre | Libre 2 | ✅ 协议已实现 |
| Abbott Libre | Libre 3 | ⏳ BLE 加密待处理 |
| Dexcom | G6 / G7 | ⏳ 私有协议待固件匹配 |
| Medtronic | Guardian 4 / Simplera | ✅ 协议框架已实现 |
| 手动输入 | App | ✅ 应急模式，无需设备 |

**CGM 品牌管理器**：`CgmBrandManager` 控制当前使用的 CGM 品牌，支持动态切换。即使设备延期未连接，手表端仍可从 Supabase 读取最新值（手动输入或历史数据）。

### 胰岛素泵
| 品牌 | 型号 | 状态 |
|------|------|------|
| Dana-R / Dana-RS | Sooil | ✅ 协议框架已实现 + 配对 |
| OmniPod | Insulet | ✅ 协议框架已实现 + 配对 |
| Medtronic | 640G / 670G / 770G | ✅ 协议框架已实现 + 配对 |
| Tandem | t:slim X2 | 🔜 待添加 |

## 多品牌手表适配

| 品牌 | 型号 | 系统 | 表盘方案 | 屏幕形状 |
|------|------|------|----------|----------|
| Apple | Apple Watch | watchOS | ClockKit Complication（Swift）| 方形 |
| OPPO | Watch 2/3/4/5 | Wear OS / HarmonyOS | Flutter Wear + 原生表盘 | 方形/圆形 |
| Samsung | Galaxy Watch | Wear OS / Tizen | Flutter Wear + Samsung Watch Face SDK | 方形 |
| Huawei | Watch | HarmonyOS | ArkTS 原生 + Watch Face Section API | 方形 |

### 表盘功能
- 实时血糖显示（每 60 秒刷新）
- 趋势方向（→ ↗ ↗↑ ↘ ↘↓）
- 低血糖 (<3.9)：蓝色背景 + 三短震
- 高血糖 (>10)：红色边框 + 闪烁
- 所有品牌数据统一走 Supabase Realtime
- CGM 延期不影响手表端：手动输入 + Supabase 历史数据
- **圆形/方形屏幕自适应**：`WatchAdaptiveLayout` 自动切换布局

## 半闭环安全边界

- App 只算不给：`sendBolus()` 抛出 `UnsupportedError`
- 用户必须在泵上手动确认
- 低血糖自动暂停建议
- 单次最大 12 单位，纠正最大 6 单位
- 全闭环：等 NMPA 批件

## 后端

Supabase 免费版：
- 500 用户 / 1GB 存储 / 500MB DB / Realtime 同步
- 注册：https://supabase.com → 创建项目 → 替换 `supabase_config.dart` 中的 URL 和 Key
- SQL 初始化脚本见 `rag_service.initSql`

## AI 健康助手（RAG）

基于 Supabase pgvector + OpenAI Embeddings + LLM 的糖尿病知识库问答：
- 用户问题 → Embedding → pgvector 相似度搜索 → Top-K 上下文 → LLM 生成回答
- 知识库包含：血糖范围、低血糖急救、饮食建议、运动建议、胰岛素存储等
- 配置 OpenAI API Key（或使用 lfree.org 免费端点）后启用

## UI 主题

- Material 3 设计规范
- 浅色/深色主题自动切换（`ThemeMode.system`）
- 圆角卡片（16px）
- Cupertino 页面过渡动画（iOS 风格）
- 医疗蓝主色 + 安全绿/警告蓝/危险红状态色

## 参考项目

| 项目 | 参考内容 | 许可证 |
|------|----------|--------|
| AndroidAPS | 泵协议 + BLE 框架 | GPL v3 |
| xDrip+ | CGM 协议 + 数据同步 | GPL v3 |
| OpenAPS | 剂量算法 (FIAST) | MIT |
| cgmpatches | 趋势箭头命名 | AGPL v3 |

## 后续开发

- Day 4-5：多品牌手表 + 官方表盘 ✅
- Day 6-7：Supabase Realtime 多端同步 + 社区 ✅
- P5：Medtronic CGM + RAG AI 助手 ✅
- P6：泵配对 + 密钥 + 手动给药指令 ✅
- UI 优化：主题 + 动画 + 圆形/方形自适应 ✅