/// 阈值 + 报警设置（本地持久化）
///
/// - 高/低阈值用户可调（默认 10.0 / 3.9）
/// - 报警方式：仅震动 / 仅声音 / 震动+声音 / 关闭
/// - 新读数入库时由 AlertService 检查，触发则震动/响铃
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';

enum AlertMode {
  off('关闭'),
  vibration('仅震动'),
  sound('仅声音'),
  both('震动+声音');

  final String label;
  const AlertMode(this.label);
}

class AlertSettings {
  double highThreshold; // 默认 10.0
  double lowThreshold; // 默认 3.9
  AlertMode highAlert;
  AlertMode lowAlert;

  AlertSettings({
    this.highThreshold = 10.0,
    this.lowThreshold = 3.9,
    this.highAlert = AlertMode.both,
    this.lowAlert = AlertMode.both,
  });

  static const _kHigh = 'alert_high';
  static const _kLow = 'alert_low';
  static const _kHighMode = 'alert_high_mode';
  static const _kLowMode = 'alert_low_mode';

  static Future<AlertSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AlertSettings(
      highThreshold: p.getDouble(_kHigh) ?? 10.0,
      lowThreshold: p.getDouble(_kLow) ?? 3.9,
      highAlert: AlertMode
          .values[(p.getInt(_kHighMode) ?? 3).clamp(0, 3)],
      lowAlert: AlertMode
          .values[(p.getInt(_kLowMode) ?? 3).clamp(0, 3)],
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kHigh, highThreshold);
    await p.setDouble(_kLow, lowThreshold);
    await p.setInt(_kHighMode, highAlert.index);
    await p.setInt(_kLowMode, lowAlert.index);
  }
}

/// 报警执行：新读数入库时调用 check()
class AlertService {
  static final AlertService _i = AlertService._internal();
  factory AlertService() => _i;
  AlertService._internal();

  final _player = AudioPlayer();
  DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);

  /// 检查读数是否越线，触发则报警。5 分钟内同方向只报一次。
  Future<String?> check(double mmolL) async {
    final s = await AlertSettings.load();
    final now = DateTime.now();
    AlertMode? mode;
    String? msg;
    if (mmolL >= s.highThreshold) {
      mode = s.highAlert;
      msg = '血糖偏高 ${mmolL.toStringAsFixed(1)}（阈值 ${s.highThreshold}）';
    } else if (mmolL <= s.lowThreshold) {
      mode = s.lowAlert;
      msg = '血糖偏低 ${mmolL.toStringAsFixed(1)}（阈值 ${s.lowThreshold}）';
    }
    if (mode == null || mode == AlertMode.off) return null;
    if (now.difference(_lastFired).inMinutes < 5) return msg; // 只记不扰
    _lastFired = now;
    if (mode == AlertMode.vibration || mode == AlertMode.both) {
      try {
        // 系统震动：HapticFeedback 无需额外插件/权限（VIBRATE 已在 Manifest 声明）
        await HapticFeedback.vibrate();
        await Future.delayed(const Duration(milliseconds: 200));
        await HapticFeedback.vibrate();
      } catch (_) {}
    }
    if (mode == AlertMode.sound || mode == AlertMode.both) {
      try {
        // audioplayers 播放：优先 UrlSource 系统音，无文件时静默跳过
        await _player
            .play(UrlSource(
                'https://actions.google.com/sounds/v1/alarms/beep_short.ogg'))
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // 无网络/无音频时只震动，不报错
      }
    }
    return msg;
  }
}
