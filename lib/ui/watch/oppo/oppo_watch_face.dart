// OPPO Watch 表盘血糖展示
// 平台：Wear OS 2 / ColorOS Watch / HarmonyOS
// 实现：Flutter Wear + 原生 Watch Face
// 数据源：Supabase Realtime
//
// Wear OS 2（OPPO Watch 2）：
//   - 使用 Flutter Wear 包
//   - 表盘：WatchFaceService + CanvasRenderer
//
// ColorOS Watch（OPPO Watch 3/4）：
//   - 手机桥接模式：手机 App → Supabase → 手表
//   - 表盘：ColorOS Watch Face SDK
//
// HarmonyOS（OPPO Watch 5）：
//   - ArkTS 原生表盘
//   - 数据订阅：Supabase Realtime

import 'package:flutter/material.dart';

// ignore: unused_import
import '../multi_watch_arch.dart';

/// OPPO Watch 表盘配置
class OppoWatchFace {
  /// Wear OS 2 表盘（OPPO Watch 2）
  static const bool supportWearOs2 = true;

  /// ColorOS Watch 表盘（OPPO Watch 3/4）
  static const bool supportColorOs = true;

  /// HarmonyOS 表盘（OPPO Watch 5）
  static const bool supportHarmonyOs = true;

  /// 低血糖显示：蓝色背景 + 三短震
  static const bool highlightLowGlucose = true;

  /// 实时更新间隔（秒）
  static const int updateInterval = 60;
}

/// Wear OS 2 表盘 Renderer（Flutter Wear）
class WearOs2GlucoseRenderer {
  final WatchGlucoseData data;

  WearOs2GlucoseRenderer(this.data);

  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: data.statusColor.withValues(alpha: 0.2),
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
