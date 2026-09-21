# V5.0 半闭环功能说明

## 半闭环流程

```
CGM 读数 → 剂量算法 (FIAST) → 建议剂量弹窗 → 用户确认 → 手动给药
```

**安全边界**
- App 只算不给：`sendBolus()` 抛出 `UnsupportedError`
- 用户必须在泵上手动确认
- 低血糖 (<3.9) 自动暂停建议
- 单次最大 12 单位
- 纠正剂量最大 6 单位

## 支持的泵品牌

| 品牌 | 协议 | 状态 |
|------|------|------|
| Dana-R / Dana-RS | Sooil | ✅ 框架已实现 |
| OmniPod | Insulet | ✅ 框架已实现 |
| Medtronic 640G/670G/770G | Medtronic | ✅ 框架已实现 |
| Tandem t:slim X2 | Tandem | 🔜 待添加 |
| Animas | Johnson & Johnson | 🔜 待添加 |

## 参考项目

| 项目 | 协议参考 | 许可证 |
|------|----------|--------|
| AndroidAPS | Dana / Medtronic / Omnipod | GPL v3 |
| xDrip+ | Dexcom / Libre / Medtronic | GPL v3 |
| OpenAPS | 算法 (FIAST / Zone MPC) | MIT |
| Loop | iOS 闭环框架 | GPL v3 |

## 已知限制

- 泵指令发送需设备配对 + 密钥（待配置）
- 全闭环未实现（法规 + 安全原因）
- 需医生确认 + NMPA 批件才能正式用于给药
