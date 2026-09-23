import 'package:flutter_test/flutter_test.dart';
import 'package:bloodsugar_v5/domain/analysis/glucose_analyst.dart';

/// 构造一条 5 分钟一条的血糖序列（mmol/L）
List<GlucosePoint> seq(List<double> vs, {DateTime? t0}) {
  final start = t0 ?? DateTime(2026, 9, 23, 12, 0);
  return [
    for (var i = 0; i < vs.length; i++)
      GlucosePoint(vs[i], start.add(Duration(minutes: 5 * i))),
  ];
}

void main() {
  group('异常波动归因', () {
    test('餐前正常、餐后2h飙到14 → 报饮食升糖，给出行为建议', () {
      // 12:00 餐前 6.0 … 14:00 14.0
      final pts = seq([6.0, 6.2, 7.5, 9.8, 12.1, 14.0]);
      final r = analyzeHigh(pts, nowIdx: 5);
      expect(r, isNotNull);
      expect(r!.cause, contains('饮食'));
      expect(r.advice.isNotEmpty, true);
      expect(r.peak, closeTo(14.0, 0.01));
    });

    test('平稳序列不报高', () {
      final pts = seq([6.0, 6.1, 5.9, 6.2, 6.0, 6.1]);
      expect(analyzeHigh(pts, nowIdx: 5), isNull);
    });

    test('夜间3点低到3.2 → 报夜间低血糖，提示15-15和查原因', () {
      final t0 = DateTime(2026, 9, 23, 0, 0);
      final pts = seq([6.5, 5.8, 4.9, 4.1, 3.5, 3.2], t0: t0);
      final r = analyzeLow(pts, nowIdx: 5);
      expect(r, isNotNull);
      expect(r!.isNight, true);
      expect(r.advice.any((a) => a.contains('15')), true);
    });

    test('白天慢降到3.5 → 非夜间，提示运动/胰岛素排查', () {
      final pts = seq([6.0, 5.4, 4.8, 4.2, 3.8, 3.5]);
      final r = analyzeLow(pts, nowIdx: 5);
      expect(r, isNotNull);
      expect(r!.isNight, false);
    });

    test('空序列/单点不崩', () {
      expect(analyzeHigh([], nowIdx: 0), isNull);
      expect(analyzeLow(seq([5.0]), nowIdx: 0), isNull);
    });
  });
}
