import 'package:flutter_test/flutter_test.dart';
import 'package:bloodsugar_v5/domain/logs/treatment_log.dart';

void main() {
  group('类型中文名', () {
    test('胰岛素/口服药/饮食/运动/备注', () {
      expect(treatmentTypeLabel('insulin'), '胰岛素');
      expect(treatmentTypeLabel('medication'), '口服药');
      expect(treatmentTypeLabel('food'), '饮食');
      expect(treatmentTypeLabel('exercise'), '运动');
      expect(treatmentTypeLabel('note'), '备注');
    });
    test('未知类型原样返回', () {
      expect(treatmentTypeLabel('xxx'), 'xxx');
    });
  });

  group('展示文案', () {
    test('胰岛素带剂量和部位', () {
      expect(
        formatTreatment(
            type: 'insulin',
            detail: '门冬',
            amount: 6,
            unit: 'U',
            extra: '腹部'),
        '门冬 6U · 腹部',
      );
    });
    test('无剂量时只显示明细', () {
      expect(
        formatTreatment(type: 'food', detail: '螺蛳粉 1 碗'),
        '螺蛳粉 1 碗',
      );
    });
  });

  group('剂量校验', () {
    test('胰岛素单次上限 12U', () {
      expect(checkInsulinDose(6), isNull);
      expect(checkInsulinDose(12), isNull);
      expect(checkInsulinDose(12.5), isNotNull);
    });
    test('零和负数不合法', () {
      expect(checkInsulinDose(0), isNotNull);
      expect(checkInsulinDose(-1), isNotNull);
    });
  });
}
