// Samsung Galaxy Watch 表盘血糖展示
// 平台：Wear OS / Tizen
// 实现：Flutter Wear + Samsung Watch Face SDK
// 数据源：Supabase Realtime
//
// Wear OS 版本：
//   - Flutter Wear + CanvasWatchFaceService
//   - 低血糖：红色边框 + 震动
//
// Tizen 版本（旧款三星手表）：
//   - Tizen Native + Watch Face API
//   - 数据同步：Supabase REST API 轮询

import 'package:flutter/material.dart';

// ignore: unused_import
import '../multi_watch_arch.dart';

/// Samsung Watch Face 配置
class SamsungWatchFace {
  /// Wear OS 表盘
  static const bool supportWearOs = true;

  /// Tizen 表盘（旧款）
  static const bool supportTizen = true;

  /// 低血糖显示：红色边框 + 闪烁
  static const bool highlightLowGlucose = true;

  /// 实时更新间隔（秒）
  static const int updateInterval = 60;
}

/// Wear OS 表盘 Renderer
class SamsungWearOsRenderer {
  final WatchGlucoseData data;

  SamsungWearOsRenderer(this.data);

  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: data.statusColor,
          width: data.isLow ? 4 : 2,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              data.mmolL.toStringAsFixed(1),
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: data.statusColor,
              ),
            ),
            Text(
              data.trendLabel,
              style: const TextStyle(fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}
