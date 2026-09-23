import 'package:flutter_test/flutter_test.dart';
import 'package:bloodsugar_v5/domain/vitals/vital_types.dart';

void main() {
  group('运动类型中文名', () {
    test('跑步/游泳/步行/骑行', () {
      expect(workoutLabel('RUNNING'), '跑步');
      expect(workoutLabel('SWIMMING'), '游泳');
      expect(workoutLabel('WALKING'), '步行');
      expect(workoutLabel('BIKING'), '骑行');
    });
    test('未知类型回退为运动', () {
      expect(workoutLabel('SKYDIVING'), '运动');
      expect(workoutLabel(''), '运动');
    });
  });

  group('指标中文名', () {
    test('心率/血氧/血压/睡眠/步数/体重/运动', () {
      expect(vitalKindLabel('heart_rate'), '心率');
      expect(vitalKindLabel('spo2'), '血氧');
      expect(vitalKindLabel('bp'), '血压');
      expect(vitalKindLabel('sleep'), '睡眠');
      expect(vitalKindLabel('steps'), '步数');
      expect(vitalKindLabel('weight'), '体重');
      expect(vitalKindLabel('workout'), '运动');
    });
  });

  group('格式化', () {
    test('睡眠分钟转x小时x分', () {
      expect(formatSleep(390), '6小时30分');
      expect(formatSleep(60), '1小时');
      expect(formatSleep(45), '45分');
    });
    test('血压收缩/舒张拼接', () {
      expect(formatBp(120, 80), '120/80');
    });
  });
}
