import 'package:health/health.dart';

/// 系统健康平台写入：把每次收到的血糖同步写一份给 Health Connect（Android）/
/// HealthKit（iOS），OPPO Watch X 的官方血糖表盘只能读系统平台的数据，读不到
/// 我们 App 私有库——这是让官方表盘有数的唯一免费通道。
class HealthBridge {
  static final _health = Health();
  static bool _authed = false;

  /// 首次调用时弹系统授权框（Health Connect），用户点允许即可
  static Future<bool> ensureAuth() async {
    if (_authed) return true;
    try {
      final types = [HealthDataType.BLOOD_GLUCOSE];
      final perms = [HealthDataAccess.READ_WRITE];
      final ok =
          await _health.requestAuthorization(types, permissions: perms);
      _authed = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 写入一条血糖（失败静默：没装 Health Connect 的机器直接跳过）
  static Future<void> writeGlucose(double mmolL, DateTime time) async {
    try {
      if (!_authed) return;
      await _health.writeHealthData(
        value: mmolL,
        type: HealthDataType.BLOOD_GLUCOSE,
        startTime: time,
        endTime: time,
        unit: HealthDataUnit.MILLIMOLES_PER_LITER,
      );
    } catch (_) {}
  }
}
