import 'package:flutter_test/flutter_test.dart';
import 'package:bloodsugar_v5/domain/report/agp.dart';

// RED:纯 Dart 统计逻辑 —— 先写期望，跑起来必须失败（agp.dart 还不存在）。
void main() {
  // 10 个点（mmol/L）：TIR 应为 6/10=60%，各分区各 10%
  final rows = [
    (5.0, DateTime(2026, 9, 20, 8, 0)),
    (5.5, DateTime(2026, 9, 20, 8, 5)),
    (3.5, DateTime(2026, 9, 20, 8, 10)), // TBR1
    (2.8, DateTime(2026, 9, 20, 8, 11)), // TBR2（与上一条连续→同一次事件）
    (11.0, DateTime(2026, 9, 20, 12, 0)), // TAR1
    (14.5, DateTime(2026, 9, 20, 18, 0)), // TAR2
    (8.0, DateTime(2026, 9, 21, 8, 0)),
    (9.0, DateTime(2026, 9, 21, 9, 0)),
    (4.0, DateTime(2026, 9, 21, 10, 0)),
    (6.0, DateTime(2026, 9, 21, 11, 0)),
  ];

  test('分区占比：TIR 60%，TBR/TAR 各级 10%', () {
    final s = AgpStats.summarize(rows, days: 2);
    expect(s.total, 10);
    expect(s.tir, closeTo(60.0, 0.01));
    expect(s.tbr1, closeTo(10.0, 0.01));
    expect(s.tbr2, closeTo(10.0, 0.01));
    expect(s.tar1, closeTo(10.0, 0.01));
    expect(s.tar2, closeTo(10.0, 0.01));
    // 五个分区加起来必须是 100%
    expect(s.tir + s.tbr1 + s.tbr2 + s.tar1 + s.tar2,
        closeTo(100.0, 0.01));
  });

  test('GMI 公式：3.31 + 0.02392 × 平均mg/dL', () {
    final s = AgpStats.summarize(rows, days: 2);
    // 均值 6.93 mmol/L → 124.87 mg/dL → GMI ≈ 6.30%
    expect(s.meanMmol, closeTo(6.93, 0.01));
    expect(s.gmi, closeTo(6.30, 0.02));
  });

  test('CV 定义：总体标准差/均值（mg/dL 口径）', () {
    final s = AgpStats.summarize(rows, days: 2);
    final vals = rows.map((r) => r.$1 * 18.0182).toList();
    final mean = vals.reduce((a, b) => a + b) / vals.length;
    final variance =
        vals.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
            vals.length;
    final sd = sqrtApprox(variance);
    expect(s.sd, closeTo(sd, 0.05));
    expect(s.cv, closeTo(sd / mean * 100, 0.05));
  });

  test('覆盖率：实测点数 / (天数×1440)', () {
    final s = AgpStats.summarize(rows, days: 2);
    expect(s.coverage, closeTo(10 / 2880 * 100, 0.001));
  });

  test('低血糖事件：连续低值合并为一次，记录起止与最低值', () {
    final s = AgpStats.summarize(rows, days: 2);
    // 3.5(08:10)+2.8(08:11) 连续 → 1 次事件，最低 2.8
    expect(s.episodes.length, 1);
    expect(s.episodes.first.minMmol, closeTo(2.8, 0.01));
    expect(s.episodes.first.minutes, 2); // 08:10→08:11 跨 2 分钟
  });

  test('AGP 全天分位：同槽多天数据聚合出中位线', () {
    // 8:00 槽有 5.0（9/20）和 8.0（9/21）→ 中位 6.5
    final s = AgpStats.summarize(rows, days: 2);
    final slot = s.slots[8 * 12]; // 8:00 → 第 96 个 5 分钟槽
    expect(slot, isNotNull);
    expect(slot!.median, closeTo(6.5, 0.01));
  });
}

double sqrtApprox(double x) {
  var g = x / 2;
  for (var i = 0; i < 50; i++) {
    g = (g + x / g) / 2;
  }
  return g;
}
