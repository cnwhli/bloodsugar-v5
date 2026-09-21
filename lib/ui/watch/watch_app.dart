import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../watch/multi_watch_arch.dart';
import 'watch_glucose_page.dart';

/// OPPO Watch 适配矩阵
///
/// | 型号 | 系统 | 方案 | 屏幕形状 |
/// |------|------|------|----------|
/// | Watch 2 | Wear OS 2 | Flutter Wear 独立运行 | 方形 |
/// | Watch 3 | ColorOS Watch | 手机桥接模式 | 圆形 |
/// | Watch 4 | HarmonyOS | 手机桥接模式 | 方形 |
/// | Watch 5 | HarmonyOS 4 | ArkTS 独立 + Supabase | 方形 |
///
/// 统一接口：手机端 BleCgmManager 收集数据
///           → Supabase Realtime 推送到手表端
///           → 手表端渲染 + 独立预警

/// 手表端入口
class WatchAppEntry {
  /// 启动手表 App
  static void run({WatchShape shape = WatchShape.rectangular}) {
    runApp(WatchApp(shape: shape));
  }
}

class WatchApp extends StatelessWidget {
  final WatchShape shape;

  const WatchApp({super.key, this.shape = WatchShape.rectangular});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '血糖管家 Watch',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: WatchGlucosePage(
        userId: 'default_user',
        shape: shape,
      ),
    );
  }
}

/// 预警助手
class AlertService {
  /// 低血糖阈值
  static const double lowThreshold = 3.9;

  /// 高血糖阈值
  static const double highThreshold = 10.0;

  static bool isLow(double mmolL) => mmolL < lowThreshold;
  static bool isHigh(double mmolL) => mmolL > highThreshold;

  /// 预警优先级
  static AlertLevel levelOf(double mmolL) {
    if (mmolL < lowThreshold) return AlertLevel.low;
    if (mmolL > highThreshold) return AlertLevel.high;
    return AlertLevel.normal;
  }

  /// 低血糖震动模式（三短震）
  static const List<int> lowVibration = [500, 200, 500, 200, 500];

  /// 高血糖震动模式（两长震）
  static const List<int> highVibration = [1000, 200, 1000];

  /// 触发预警震动
  static Future<void> triggerVibration(AlertLevel level) async {
    final pattern = level == AlertLevel.low ? lowVibration : highVibration;
    for (final duration in pattern) {
      HapticFeedback.heavyImpact();
      await Future.delayed(Duration(milliseconds: duration));
    }
  }
}

enum AlertLevel { normal, low, high }