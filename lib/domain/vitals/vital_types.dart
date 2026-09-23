/// 生命体征类型标签 + 格式化（纯 Dart，可单测）
///
/// 对应 health 插件的 WorkoutActivityType 名字和本地 vitals 表的 kind。
library;

const Map<String, String> _workoutLabels = {
  'RUNNING': '跑步',
  'WALKING': '步行',
  'SWIMMING': '游泳',
  'BIKING': '骑行',
  'CYCLING': '骑行',
  'HIKING': '徒步',
  'YOGA': '瑜伽',
  'DANCE': '舞蹈',
  'FITNESS': '健身',
};

/// 运动类型英文名 → 中文
String workoutLabel(String type) => _workoutLabels[type] ?? '运动';

const Map<String, String> _vitalKindLabels = {
  'heart_rate': '心率',
  'resting_hr': '静息心率',
  'spo2': '血氧',
  'bp': '血压',
  'sleep': '睡眠',
  'steps': '步数',
  'weight': '体重',
  'workout': '运动',
  'calories': '消耗',
};

/// vitals 表 kind → 中文
String vitalKindLabel(String kind) => _vitalKindLabels[kind] ?? kind;

/// 睡眠分钟数 → "x小时x分"
String formatSleep(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h > 0 && m > 0) return '${h}小时${m}分';
  if (h > 0) return '${h}小时';
  return '${m}分';
}

/// 血压 "收缩/舒张"
String formatBp(int systolic, int diastolic) => '$systolic/$diastolic';
