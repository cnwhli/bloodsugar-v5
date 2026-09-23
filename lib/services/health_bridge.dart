import 'package:health/health.dart';

/// 单条运动记录（今日运动明细用）
class WorkoutItem {
  final String type; // HealthWorkoutActivityType.name，如 RUNNING
  final int minutes;
  final int? calories;
  const WorkoutItem({
    required this.type,
    required this.minutes,
    this.calories,
  });
}

/// 今日健康全量快照：字段全可空，平台没数就 null，上层显示"--"，不抛错。
class HealthSnapshot {
  final int? bpm;
  final int? restingHr;
  final double? spo2;
  final int? systolic;
  final int? diastolic;
  final double? weightKg;
  final int? steps;
  final int? sleepMin;
  final double? walkRunKm;
  final double? swimKm;
  final double? cycleKm;
  final double? caloriesKcal;
  final List<WorkoutItem> workouts;
  const HealthSnapshot({
    this.bpm,
    this.restingHr,
    this.spo2,
    this.systolic,
    this.diastolic,
    this.weightKg,
    this.steps,
    this.sleepMin,
    this.walkRunKm,
    this.swimKm,
    this.cycleKm,
    this.caloriesKcal,
    this.workouts = const [],
  });

  int get workoutMin =>
      workouts.fold(0, (sum, w) => sum + w.minutes);
}

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
        HealthDataType.BLOOD_OXYGEN,
        HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
        HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
        HealthDataType.STEPS,
        HealthDataType.WEIGHT,
        HealthDataType.WORKOUT,
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_IN_BED,
        HealthDataType.DISTANCE_WALKING_RUNNING,
        HealthDataType.DISTANCE_SWIMMING,
        HealthDataType.DISTANCE_CYCLING,
        HealthDataType.ACTIVE_ENERGY_BURNED,
      ];
      final perms =
          List.filled(types.length, HealthDataAccess.READ);
      final ok =
          await _health.requestAuthorization(types, permissions: perms);
      _sportAuthed = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// 今日健康全量快照（首页健康卡片 + 后台同步入库用）。
  /// 字段全可空：平台没数就 null，上层显示"--"，不抛错。
  static Future<HealthSnapshot> readTodaySnapshot() async {
    const empty = HealthSnapshot();
    try {
      if (!await ensureSportAuth()) return empty;
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);

      Future<double?> lastNum(List<HealthDataType> types,
          {bool newest = true}) async {
        try {
          final pts = await _health.getHealthDataFromTypes(
            types: types,
            startTime: dayStart,
            endTime: now,
          );
          if (pts.isEmpty) return null;
          pts.sort((a, b) => newest
              ? b.dateTo.compareTo(a.dateTo)
              : a.dateTo.compareTo(b.dateTo));
          final v = (pts.first.value as NumericHealthValue).numericValue;
          return v.toDouble();
        } catch (_) {
          return null;
        }
      }

      final bpmD = await lastNum([HealthDataType.HEART_RATE]);
      final restD = await lastNum([HealthDataType.RESTING_HEART_RATE]);
      final spo2D = await lastNum([HealthDataType.BLOOD_OXYGEN]);
      final sysD = await lastNum([HealthDataType.BLOOD_PRESSURE_SYSTOLIC]);
      final diaD = await lastNum([HealthDataType.BLOOD_PRESSURE_DIASTOLIC]);
      final weightD = await lastNum([HealthDataType.WEIGHT]);

      int? steps;
      try {
        steps = await _health.getTotalStepsInInterval(dayStart, now);
      } catch (_) {}

      // 睡眠：昨晚 18 点 → 今晨（跨天，取各阶段分钟和）
      int? sleepMin;
      try {
        final sleepStart =
            DateTime(now.year, now.month, now.day).subtract(
          const Duration(hours: 6),
        );
        final sp = await _health.getHealthDataFromTypes(
          types: [
            HealthDataType.SLEEP_ASLEEP,
            HealthDataType.SLEEP_LIGHT,
            HealthDataType.SLEEP_DEEP,
            HealthDataType.SLEEP_REM,
            HealthDataType.SLEEP_IN_BED,
          ],
          startTime: sleepStart,
          endTime: now,
        );
        var secs = 0;
        for (final p in sp) {
          secs += p.dateTo.difference(p.dateFrom).inSeconds;
        }
        if (sp.isNotEmpty) sleepMin = secs ~/ 60;
      } catch (_) {}

      // 运动明细：今日每条 workout（类型中文名 + 分钟 + 卡路里）
      final workouts = <WorkoutItem>[];
      try {
        final wo = await _health.getHealthDataFromTypes(
          types: [HealthDataType.WORKOUT],
          startTime: dayStart,
          endTime: now,
        );
        for (final p in wo) {
          final v = p.value;
          if (v is WorkoutHealthValue) {
            workouts.add(WorkoutItem(
              type: v.workoutActivityType.name,
              minutes:
                  p.dateTo.difference(p.dateFrom).inMinutes,
              calories: v.totalEnergyBurned,
            ));
          }
        }
      } catch (_) {}

      // 距离（步行+跑步 / 游泳 / 骑行，平台规范单位是米，换算到 km）
      double? _km(HealthDataPoint p) {
        try {
          final v = (p.value as NumericHealthValue).numericValue.toDouble();
          if (p.unit == HealthDataUnit.METER) return v / 1000;
          return v > 100 ? v / 1000 : v; // 未知单位：大数当米，小数当km
        } catch (_) {
          return null;
        }
      }

      double walkRunKm = 0, swimKm = 0, cycleKm = 0;
      var hasDist = false;
      try {
        final dp = await _health.getHealthDataFromTypes(
          types: [
            HealthDataType.DISTANCE_WALKING_RUNNING,
            HealthDataType.DISTANCE_SWIMMING,
            HealthDataType.DISTANCE_CYCLING,
          ],
          startTime: dayStart,
          endTime: now,
        );
        for (final p in dp) {
          final km = _km(p);
          if (km == null) continue;
          hasDist = true;
          if (p.type == HealthDataType.DISTANCE_SWIMMING) {
            swimKm += km;
          } else if (p.type == HealthDataType.DISTANCE_CYCLING) {
            cycleKm += km;
          } else {
            walkRunKm += km;
          }
        }
      } catch (_) {}

      double? calories;
      try {
        final cp = await _health.getHealthDataFromTypes(
          types: [HealthDataType.ACTIVE_ENERGY_BURNED],
          startTime: dayStart,
          endTime: now,
        );
        var sum = 0.0;
        for (final p in cp) {
          sum +=
              (p.value as NumericHealthValue).numericValue.toDouble();
        }
        if (cp.isNotEmpty) calories = sum;
      } catch (_) {}

      return HealthSnapshot(
        bpm: bpmD?.round(),
        restingHr: restD?.round(),
        spo2: spo2D,
        systolic: sysD?.round(),
        diastolic: diaD?.round(),
        weightKg: weightD,
        steps: steps,
        sleepMin: sleepMin,
        walkRunKm: hasDist ? walkRunKm : null,
        swimKm: hasDist ? swimKm : null,
        cycleKm: hasDist ? cycleKm : null,
        caloriesKcal: calories,
        workouts: workouts,
      );
    } catch (_) {
      return empty;
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
