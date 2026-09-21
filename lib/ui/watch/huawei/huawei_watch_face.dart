// 华为 Watch 表盘血糖展示
// 平台：HarmonyOS
// 实现：ArkTS 原生 + Watch Face Section API
// 数据源：Supabase Realtime
//
// 华为手表表盘开发：
//   1. 使用 HarmonyOS ArkTS
//   2. 表盘配置：watchface.json
//   3. 数据渲染：Canvas 绘制
//   4. 实时同步：Supabase Realtime（WebSocket）

import 'package:flutter/material.dart';

// ignore: unused_import
import '../multi_watch_arch.dart';

/// 华为 Watch Face 配置
class HuaweiWatchFace {
  /// HarmonyOS 表盘
  static const bool supportHarmonyOs = true;

  /// 低血糖显示：蓝色背景 + 三短震
  static const bool highlightLowGlucose = true;

  /// 实时更新间隔（秒）
  static const int updateInterval = 60;
}

/// 华为表盘数据模型（ArkTS 侧）
/// 供 HarmonyOS 工程参考
class HuaweiGlucoseData {
  final double mmolL;
  final int trend;
  final bool isLow;
  final bool isHigh;

  HuaweiGlucoseData({
    required this.mmolL,
    required this.trend,
    this.isLow = false,
    this.isHigh = false,
  });

  String get trendLabel {
    switch (trend) {
      case 0: return '→';
      case 1: return '↗';
      case 2: return '↗↑';
      case 3: return '↘';
      case 4: return '↘↓';
      default: return '--';
    }
  }
}
