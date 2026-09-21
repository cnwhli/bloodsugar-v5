/// 多品牌手表适配架构
///
/// 数据流：
///   手机 App → Supabase Realtime → 各品牌手表端
///
/// CGM 设备连接延期，不影响手表端已有的血糖显示能力：
///   - 手机端可手动输入血糖值（应急）
///   - 手表端从 Supabase 读取最新值（无论来源）
///   - 各品牌表盘从 Supabase 订阅，实时更新
///
/// 各平台表盘实现：
///   - Apple Watch:   SwiftUI + ClockKit Complication
///   - OPPO Watch:    Flutter Wear + 原生 Watch Face
///   - Samsung:       Flutter Wear + Samsung Watch Face SDK
///   - Huawei:        ArkTS 原生 + Watch Face Section API
///
/// 统一接口：所有手表端从 Supabase 订阅 glucose_readings 变化

import 'package:flutter/material.dart';

// ==================== 手表屏幕形状 ====================

/// 手表屏幕形状（用于自适应布局）
enum WatchShape {
  circular('圆形', true),    // OPPO Watch 圆形款、Apple Watch 圆形
  rectangular('方形', false), // 大多数方形手表
  ;

  final String displayName;
  final bool isCircular;
  const WatchShape(this.displayName, this.isCircular);
}

/// 检测手表屏幕形状
/// 返回当前设备是圆形还是方形
WatchShape detectWatchShape() {
  // 实际运行时通过 MediaQuery 或平台 API 检测
  // 此处返回默认值，实际由各平台原生代码传入
  return WatchShape.rectangular;
}

// ==================== 自适应布局组件 ====================

/// 手表端自适应布局组件
/// 根据屏幕形状（圆形/方形）自动切换布局
class WatchAdaptiveLayout extends StatelessWidget {
  final WatchShape shape;
  final Widget child;
  final EdgeInsets? padding;

  const WatchAdaptiveLayout({
    super.key,
    required this.shape,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    if (shape.isCircular) {
      return _CircularWatchLayout(
        child: child,
        padding: padding ?? const EdgeInsets.all(8),
      );
    }
    return _RectangularWatchLayout(
      child: child,
      padding: padding ?? const EdgeInsets.all(12),
    );
  }
}

/// 圆形手表布局（OPPO Watch 圆形款等）
/// 特点：四角圆润、内容居中、避免边缘元素
class _CircularWatchLayout extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _CircularWatchLayout({required this.child, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: ClipOval(
        child: SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: Center(
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 方形手表布局（大多数智能手表）
/// 特点：全屏利用、支持更多元素、边缘可用
class _RectangularWatchLayout extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _RectangularWatchLayout({required this.child, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: child,
    );
  }
}

// ==================== CGM 品牌管理 ====================

/// 支持的 CGM 品牌（可按需启用/禁用）
enum CgmBrand {
  libre2('Libre 2', 'Abbott', true),     // ✅ 协议已实现
  libre3('Libre 3', 'Abbott', false),     // ⏳ BLE 加密待处理
  dexcomG6('Dexcom G6', 'Dexcom', false), // ⏳ 私有协议待固件匹配
  dexcomG7('Dexcom G7', 'Dexcom', false), // ⏳ 私有协议待固件匹配
  medtronic('Medtronic Guardian', 'Medtronic', false), // 🔜 待添加
  manual('手动输入', 'App', true),         // ✅ 应急模式，无需设备
  ;

  final String displayName;
  final String manufacturer;
  final bool available; // 是否当前可用
  const CgmBrand(this.displayName, this.manufacturer, this.available);
}

/// CGM 品牌管理器
/// 控制当前使用的 CGM 品牌，支持动态切换
class CgmBrandManager {
  static final CgmBrandManager _instance = CgmBrandManager._internal();
  factory CgmBrandManager() => _instance;
  CgmBrandManager._internal();

  CgmBrand _current = CgmBrand.manual;

  CgmBrand get current => _current;

  /// 可用品牌列表（当前可连接的）
  List<CgmBrand> get availableBrands => CgmBrand.values
      .where((b) => b.available)
      .toList();

  /// 全部品牌列表（含延期的）
  List<CgmBrand> get allBrands => CgmBrand.values.toList();

  /// 切换品牌
  void switchBrand(CgmBrand brand) {
    _current = brand;
  }

  /// 当前品牌是否已连接（手动输入模式始终连接）
  bool get isConnected {
    if (_current == CgmBrand.manual) return true;
    // BLE 连接状态由 ble_scanner_screen.dart 管理
    return false;
  }
}

// ==================== 手表品牌枚举 ====================

/// 手表品牌枚举
enum WatchBrand {
  apple('Apple Watch', 'watchOS'),
  oppo('OPPO Watch', 'Wear OS / HarmonyOS'),
  samsung('Samsung Galaxy Watch', 'Wear OS / Tizen'),
  huawei('华为 Watch', 'HarmonyOS'),
  garmin('Garmin', 'Garmin OS'),
  fitbit('Fitbit', 'Fitbit OS');

  final String displayName;
  final String os;
  const WatchBrand(this.displayName, this.os);
}

// ==================== 手表端血糖数据模型 ====================

/// 手表端血糖数据模型
class WatchGlucoseData {
  final double mmolL;
  final int trend;
  final String brand;
  final DateTime timestamp;
  final bool isLow;
  final bool isHigh;

  WatchGlucoseData({
    required this.mmolL,
    required this.trend,
    required this.brand,
    required this.timestamp,
    this.isLow = false,
    this.isHigh = false,
  });

  Color get statusColor {
    if (isLow) return Colors.blue;
    if (isHigh) return Colors.red;
    return Colors.green;
  }

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

// ==================== Supabase Realtime 手表数据服务 ====================

/// Supabase Realtime 手表数据服务
/// 所有手表端共用：订阅用户血糖变化 → 更新表盘
class WatchSyncService {
  static final WatchSyncService _instance = WatchSyncService._internal();
  factory WatchSyncService() => _instance;
  WatchSyncService._internal();

  /// 订阅用户血糖实时数据
  /// 手表端启动时调用，收到推送后更新表盘
  void subscribe(String userId, void Function(WatchGlucoseData) onUpdate) {
    // Supabase Realtime 订阅
    // Supabase.instance.client
    //     .channel('glucose:$userId')
    //     .onPostgresChanges(
    //       event: 'UPDATE',
    //       schema: 'public',
    //       table: 'glucose_readings',
    //       callback: (payload) {
    //         final data = WatchGlucoseData.fromJson(payload['new']);
    //         onUpdate(data);
    //       },
    //     )
    //     .subscribe();
  }

  /// 手动刷新（表盘下拉触发）
  Future<WatchGlucoseData> fetchLatest(String userId) async {
    // 从 Supabase 读取最新血糖
    // return WatchGlucoseData.fromJson(...);
    throw UnimplementedError('fetchLatest 需配置 Supabase');
  }
}

// ==================== 低血糖预警配置 ====================

/// 低血糖预警配置
class WatchAlertConfig {
  static const double lowThreshold = 3.9;
  static const double highThreshold = 10.0;

  /// 预警震动模式
  static const List<int> lowVibration = [500, 200, 500, 200, 500];
  static const List<int> highVibration = [1000, 200, 1000];

  static bool isLow(double mmolL) => mmolL < lowThreshold;
  static bool isHigh(double mmolL) => mmolL > highThreshold;
}