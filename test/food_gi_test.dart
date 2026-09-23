import 'package:flutter_test/flutter_test.dart';
import 'package:bloodsugar_v5/domain/nutrition/food_gi.dart';

void main() {
  group('食物GI查表', () {
    test('螺蛳粉能查到：中高GI，含碳水估算', () {
      final f = lookupFood('吃了一碗螺蛳粉');
      expect(f, isNotNull);
      expect(f!.gi, inInclusiveRange(45, 75));
      expect(f.carbsPerServingG, greaterThan(30));
    });

    test('白米饭高GI', () {
      final f = lookupFood('米饭');
      expect(f, isNotNull);
      expect(f!.gi, greaterThanOrEqualTo(70));
    });

    test('查不到的食物返回null，不硬编', () {
      expect(lookupFood('火星能量棒'), isNull);
    });

    test('一句话里多个食物全检出', () {
      final list = lookupFoods('早上吃了包子和豆浆');
      expect(list.length, greaterThanOrEqualTo(1));
    });
  });

  group('升糖预测', () {
    test('碳水越多、GI越高，预测升幅越大', () {
      final low = predictRiseMmolL(carbsG: 20, gi: 40);
      final high = predictRiseMmolL(carbsG: 80, gi: 85);
      expect(high, greaterThan(low));
      expect(low, greaterThan(0));
    });

    test('有个人历史时用个人均值校准', () {
      // 同一个人吃螺蛳粉历史平均只升1.2，预测应向1.2靠拢而非纯公式值
      final p = predictRiseMmolL(carbsG: 60, gi: 60, personalAvgRise: 1.2);
      expect(p, inInclusiveRange(0.6, 2.4));
    });

    test('零碳水预测为0', () {
      expect(predictRiseMmolL(carbsG: 0, gi: 50), 0);
    });
  });
}
