# V5.0 开发计划

## Day 1（今天）✅
- Flutter 项目骨架
- BLE 多品牌抽象层（Libre 2/3, Dexcom G6/G7, Medtronic）
- 胰岛素泵协议层（Dana-R, OmniPod, Medtronic）+ 半闭环剂量算法
- 剂量确认页面（弹窗 + 安全边界）
- Supabase 免费后端配置 + SQL
- OPPO Watch 适配方案

## Day 2-3 ✅
- 完整 BLE 连接流程（扫描→配对→订阅→实时数据流）
- 血糖圆环 UI + 趋势方向
- 数据持久化（drift SQLite）
- 数据库写入 + 周统计

## Day 4-5 ✅
- 多品牌手表适配（华为、OPPO、Apple、三星）
- 低/高血糖预警 + 震动 + 表盘醒目显示
- 各平台表盘骨架（Apple ClockKit / OPPO Flutter Wear / Samsung Wear OS + Tizen / Huawei HarmonyOS）
- WatchGlucosePage + AlertService + WatchSyncService

## Day 6-7 ✅
- Supabase Realtime 多端同步
- 糖友社区（动态发布 + 点赞 + 标签）
- 家属远程查看
- SyncService + CommunityService

## P5 ✅
- Medtronic Guardian 4 / Simplera 协议实现
- RAG AI 健康助手（pgvector + Embeddings + LLM）
- AI 健康助手 UI + 知识库 SQL 初始化脚本

## P6 ✅
- 泵配对流程（扫描→配对→密钥交换）
- 密钥安全存储（flutter_secure_storage）
- 手动给药指令（剂量计算 + 安全检查 + 泵指令发送）
- PumpPairScreen + ManualBolusScreen + PumpKeyManager
- CgmBrandManager 控制当前 CGM 品牌
- 支持动态切换品牌（手动输入/应急模式）
- CGM 延期不影响手表端：Supabase 历史数据 + 手动输入
- 所有品牌统一走 Supabase Realtime

## UI 优化 ✅
- Material 3 主题（浅色/深色自动切换）
- 圆角卡片 + Cupertino 页面过渡动画
- 手表圆形/方形屏幕自适应（WatchAdaptiveLayout）
- 医疗蓝主色 + 安全绿/警告蓝/危险红状态色
- iOS 需要 HealthKit 中转，不能直连 BLE（苹果限制）
- Libre 3 的 BLE 加密需要额外处理（当前框架已预留）
- Dexcom G6/G7 私有协议需要设备固件版本匹配
- 泵指令发送需设备配对 + 密钥（待配置）

## 半闭环安全边界（不变）
- App 只算不给
- 用户手动确认
- 低血糖自动暂停
- 单次最大 12U，纠正最大 6U
- 全闭环：等 NMPA 批件
