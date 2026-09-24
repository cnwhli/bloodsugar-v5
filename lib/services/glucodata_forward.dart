import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// GlucoData 标准广播转发（协议来自 pachi81/GlucoDataHandler，MIT 许可）。
///
/// Juggluco、xDrip、DiaBLE 等开源 App 都往这个 action 发数：
/// action = `glucodata.Minute`，extras 键如下——
/// - `glucodata.Minute.mgdl` (int)：血糖 mg/dL
/// - `glucodata.Minute.glucose` (float)：血糖 mmol/L
/// - `glucodata.Minute.Rate` (float)：变化速率 mg/dL/min
/// - `glucodata.Minute.Time` (long)：毫秒时间戳
/// - `glucodata.Minute.SerialNumber` (String)：发射器序列号
/// - `glucodata.Minute.Delta` (float)：与上一分钟差值
/// - `glucodata.Minute.Alarm` (int)：报警状态
///
/// 发了之后：第三方表盘、车机（Android Auto）、Tasker、xDrip+ 等
/// 只要订阅这个 action 就能读到我们的数，生态互通。
class GlucoDataForward {
  static const _ch = MethodChannel('bloodsugar/glucodata');
  static String? _lastKey;

  /// 每分钟调一次（蓝牙页/前台服务收到新数后调用）。
  /// 同一分钟重复调用自动跳过，不刷屏。
  static Future<void> push({
    required double mmolL,
    required double rateMgDlMin,
    required DateTime time,
    String sensorId = '',
    double delta = 0,
    int alarm = 0,
  }) async {
    if (!Platform.isAndroid) return;
    final key =
        '${time.millisecondsSinceEpoch ~/ 60000}|${(mmolL * 18.0182).round()}';
    if (key == _lastKey) return;
    _lastKey = key;
    try {
      await _ch.invokeMethod('broadcast', {
        'mgdl': (mmolL * 18.0182).round(),
        'glucose': mmolL,
        'rate': rateMgDlMin,
        'time': time.millisecondsSinceEpoch,
        'serial': sensorId,
        'delta': delta,
        'alarm': alarm,
      });
    } catch (_) {}
  }
}
