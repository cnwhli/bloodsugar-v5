import 'package:home_widget/home_widget.dart';

/// 手机桌面小组件桥：血糖 + 心率/步数推到桌面（home_widget 插件）。
///
/// 小组件本体是原生 RemoteViews（GlucoseWidgetProvider.kt），Flutter 侧只管
/// 存 6 个字段 + 触发刷新。每次新数进来调一次 push，开销一次 SharedPrefs 写。
class PhoneWidget {
  PhoneWidget._();

  static const _androidName = 'GlucoseWidgetProvider';

  static bool _supportedPin = false;

  /// 是否支持一键钉到桌面（Android 8+ 部分桌面支持，荣耀 MagicOS 支持）。
  /// 不支持就提示用户长按桌面手动加。
  static Future<bool> isPinSupported() async {
    try {
      _supportedPin =
          await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } catch (_) {
      _supportedPin = false;
    }
    return _supportedPin;
  }

  /// 一键把小组件钉到桌面（支持的桌面才有效）
  static Future<void> requestPin() async {
    try {
      await HomeWidget.requestPinWidget(androidName: _androidName);
    } catch (_) {}
  }

  /// 推送新数到桌面：血糖值 + 趋势箭头 + 时间 + 心率/步数（可选）。
  /// trendLabel 传 dashboard 的 _trend（如 '↗ 快升'），颜色按范围来。
  static Future<void> push({
    required double mmolL,
    required String trendLabel,
    required String time,
    int? bpm,
    int? steps,
  }) async {
    try {
      final color = mmolL < 3.9
          ? 0xFF5AC8FA // 低：蓝
          : mmolL > 10.0
              ? 0xFFFF3B30 // 高：红
              : 0xFF34C759; // 范围内：绿
      await Future.wait([
        HomeWidget.saveWidgetData('bg_value', mmolL.toStringAsFixed(1)),
        HomeWidget.saveWidgetData('bg_trend', trendLabel),
        HomeWidget.saveWidgetData('bg_time', '更新于 $time'),
        HomeWidget.saveWidgetData('bg_color', color),
        if (bpm != null)
          HomeWidget.saveWidgetData('bg_hr', '$bpm bpm')
        else
          HomeWidget.saveWidgetData<String?>('bg_hr', null),
        if (steps != null)
          HomeWidget.saveWidgetData(
              'bg_steps', steps >= 10000 ? '${(steps / 10000).toStringAsFixed(1)}万步' : '$steps步')
        else
          HomeWidget.saveWidgetData<String?>('bg_steps', null),
      ]);
      await HomeWidget.updateWidget(androidName: _androidName);
    } catch (_) {}
  }
}
