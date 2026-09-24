import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 手表/手机硬件传感器直读（心率 + 计步），不经过 Health Connect/欢太健康。
///
/// 国产设备（OPPO Watch X / 荣耀 Magic V2）没有谷歌框架、欢太又不给同步
/// 开关，中转链路走不通——直接读 TYPE_HEART_RATE / TYPE_STEP_COUNTER 硬件，
/// 有传感器就有数，没传感器（或没戴表）就 null，上层显示 `--`。
class WatchSensors {
  static const _methods =
      MethodChannel('watch_sensors/methods');
  static const _hrEvents =
      EventChannel('watch_sensors/heart_rate');

  /// BODY_SENSORS 授权（心率需要；计步要 ACTIVITY_RECOGNITION）。
  /// SDK ≤ 28 计步走的是定位类权限，这里统一要两项，拒绝就返回 false。
  static Future<bool> ensurePermission() async {
    try {
      final results = await [
        Permission.sensors,
        Permission.activityRecognition,
      ].request();
      return (results[Permission.sensors]?.isGranted ?? true) &&
          (results[Permission.activityRecognition]?.isGranted ?? true);
    } catch (_) {
      return false;
    }
  }

  /// 设备有没有心率/计步硬件（手表没传感器直接显示 --，不转菊花）
  static Future<({bool hr, bool steps})> available() async {
    try {
      final hr = await _methods.invokeMethod<bool>('hasHeartRate') ?? false;
      final st = await _methods.invokeMethod<bool>('hasStepCounter') ?? false;
      return (hr: hr, steps: st);
    } catch (_) {
      return (hr: false, steps: false);
    }
  }

  /// 一次读最新值：bpm（没戴表/没测到就 null）+ 今日步数
  static Future<({int? bpm, int? steps})> latest() async {
    try {
      final m =
          await _methods.invokeMapMethod<String, dynamic>('latest');
      if (m == null) return (bpm: null, steps: null);
      final bpm = (m['bpm'] as num?)?.toInt();
      final steps = (m['steps'] as num?)?.toInt();
      return (
        bpm: (bpm != null && bpm > 0) ? bpm : null,
        steps: steps,
      );
    } catch (_) {
      return (bpm: null, steps: null);
    }
  }

  /// 心率实时流（手表抬腕即刷；无传感器就不订阅）
  static Stream<int> heartRateStream() {
    return _hrEvents.receiveBroadcastStream().map((e) {
      if (e is int) return e;
      return int.tryParse('$e') ?? 0;
    }).where((v) => v > 0);
  }
}
