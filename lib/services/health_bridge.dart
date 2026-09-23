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

  /// 运动/心率档授权（手表表盘的心率、步数、运动时长从这里读。
  /// 和血糖分开要：只装手机的人不会被多弹框）
  static bool _sportAuthed = false;
  static Future<bool> ensureSportAuth() async {
    if (_sportAuthed) return true;
    try {
      final types = [
        HealthDataType.HEART_RATE,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.STEPS,
        HealthDataType.WORKOUT,
      ];
      final perms = [
        HealthDataAccess.READ,
        HealthDataAccess.READ,
        HealthDataAccess.READ,
        HealthDataAccess.READ,
      ];
      final ok =
          await _health.requestAuthorization(types, permissions: perms);
      _sportAuthed = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 今日心率（最新一条）+ 步数 + 运动分钟数。失败返回 null，不抛错。
  static Future<({int? bpm, int? steps, int? workoutMin})>
      readSportToday() async {
    try {
      if (!await ensureSportAuth()) return (bpm: null, steps: null, workoutMin: null);
      final now = DateTime.now();
      final dayStart =
          DateTime(now.year, now.month, now.day);
      final hr = await _health.getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
        startTime: dayStart,
        endTime: now,
      );
      int? bpm;
      if (hr.isNotEmpty) {
        hr.sort((a, b) => b.dateTo.compareTo(a.dateTo));
        bpm = int.tryParse(
            '${hr.first.value}'.replaceAll(RegExp(r'[^0-9]'), ''));
      }
      int? steps;
      try {
        steps = await _health.getTotalStepsInInterval(dayStart, now);
      } catch (_) {}
      int? workoutMin;
      try {
        final wo = await _health.getHealthDataFromTypes(
          types: [HealthDataType.WORKOUT],
          startTime: dayStart,
          endTime: now,
        );
        var secs = 0;
        for (final p in wo) {
          secs += p.dateTo.difference(p.dateFrom).inSeconds;
        }
        if (wo.isNotEmpty) workoutMin = secs ~/ 60;
      } catch (_) {}
      return (bpm: bpm, steps: steps, workoutMin: workoutMin);
    } catch (_) {
      return (bpm: null, steps: null, workoutMin: null);
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
