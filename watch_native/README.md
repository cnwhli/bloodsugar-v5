// 原生手表模块（Wear OS / ColorOS Watch）：Canvas 血糖表盘 + 心率步数并发症。
//
// 定位：独立模块 watch_native，打 wear 专用 APK，直装到 OPPO Watch。
// 手机 App 通过 Data Layer（/glucose 数据项）把血糖推送到手表，
// 表盘收到即画——不走 Health Connect、不经过任何封闭平台。
//
// 数据流：手机前台/后台 isolate 收到数 → DataClient.putDataItem("/glucose")
//   → 手表 GlucoseDataListenerService.onDataChanged → 存 SharedPreferences
//   → 表盘 Renderer 下一帧画出。延迟秒级，断连显示上次数 + 时间。
//
// 表盘布局（466x466 圆形，OPPO Watch X）：
//   中央：血糖大数字 + mmol/L + 趋势箭头（抬腕即见，2 米可读）
//   上方：时间 HH:MM（系统时间，息屏也走，低功耗）
//   下方三小项：心率 bpm / 步数 / 更新于 HH:MM:SS
// 息屏（ambient）：只画时间 + 血糖数字白字，不画秒和步数（省电 + 防烧屏，
//   按官方《第三方应用功耗设计指导规范》：ambient 下 1 分钟刷新一次即可）。
//
// 构建：Android Studio 打开 watch_native/ → Run 到手表（adb over WiFi）。
// CI 暂不打 wear 包（runner 无 Wear SDK），手机 APK 仍走现有 build.yml。

// ---------- 手机侧发送（Dart 侧待接：见 docs/watch_native_plan.md） ----------
// final dataClient = Wearable.getDataClient(context); // play-services-wearable
// PutDataMapRequest req = PutDataMapRequest.create("/glucose");
// req.getDataMap().putDouble("mmol", reading.valueMmolL);
// req.getDataMap().putDouble("mgdl", reading.valueMgDl);
// req.getDataMap().putInt("trend", reading.trend);
// req.getDataMap().putLong("ts", reading.timestamp.millisecondsSinceEpoch);
// Wearable.getDataClient(ctx).putDataItem(req.asPutDataRequest().setUrgent());
