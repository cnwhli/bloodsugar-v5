import 'dart:math' as math;

/// AGP（动态血糖图谱）核心统计——纯 Dart，无 Flutter 依赖，可单测。
///
/// 口径对齐《动态葡萄糖图谱报告临床应用专家共识（2023）》+ 国际 TIR 共识：
/// - 分区：TBR2(<3.0) / TBR1(3.0–3.8) / TIR(3.9–10.0) / TAR1(10.1–13.9) / TAR2(>13.9)，单位 mmol/L
/// - GMI(%) = 3.31 + 0.02392 × 平均葡萄糖(mg/dL)
/// - CV(%) = 总体标准差 / 均值 × 100（mg/dL 口径）
/// - 覆盖率 = 实测点数 / (天数 × 1440) × 100（每分钟 1 点为满格）
class AgpStats {
  final int total;
  final double tir, tbr1, tbr2, tar1, tar2; // 百分比 0–100
  final double meanMmol; // 平均 mmol/L
  final double gmi; // %
  final double sd; // mg/dL 总体标准差
  final double cv; // %
  final double coverage; // %
  final List<HypoEpisode> episodes; // 低血糖事件（<3.9 连续段合并）
  final Map<int, SlotStat> slots; // key: 0–287（5 分钟槽），全天分位线用

  const AgpStats({
    required this.total,
    required this.tir,
    required this.tbr1,
    required this.tbr2,
    required this.tar1,
    required this.tar2,
    required this.meanMmol,
    required this.gmi,
    required this.sd,
    required this.cv,
    required this.coverage,
    required this.episodes,
    required this.slots,
  });

  /// 输入：(mmol/L, 时间戳) 列表；days：统计窗天数（覆盖率分母用）。
  static AgpStats summarize(List<(double, DateTime)> rows, {int days = 14}) {
    const mg = 18.0182;
    final n = rows.length;
    if (n == 0) {
      return const AgpStats(
        total: 0, tir: 0, tbr1: 0, tbr2: 0, tar1: 0, tar2: 0,
        meanMmol: 0, gmi: 0, sd: 0, cv: 0, coverage: 0,
        episodes: [], slots: {},
      );
    }
    var cTir = 0, cTbr1 = 0, cTbr2 = 0, cTar1 = 0, cTar2 = 0;
    var sumMg = 0.0;
    final mgVals = <double>[];
    final sorted = List.of(rows)..sort((a, b) => a.$2.compareTo(b.$2));

    // 低血糖事件：<3.9 的连续段（相邻两点间隔 ≤ 15 分钟算连续）合并为一次
    final episodes = <HypoEpisode>[];
    DateTime? epStart;
    DateTime? epPrev;
    var epMin = double.infinity;
    void closeEp() {
      if (epStart != null && epPrev != null) {
        episodes.add(HypoEpisode(
          start: epStart!,
          end: epPrev!,
          minMmol: epMin,
        ));
        epStart = null;
        epPrev = null;
        epMin = double.infinity;
      }
    }

    // 全天 5 分钟槽聚合
    final slotVals = <int, List<double>>{};
    for (final (v, t) in sorted) {
      if (v < 3.0) {
        cTbr2++;
      } else if (v <= 3.8) {
        cTbr1++;
      } else if (v <= 10.0) {
        cTir++;
      } else if (v <= 13.9) {
        cTar1++;
      } else {
        cTar2++;
      }
      sumMg += v * mg;
      mgVals.add(v * mg);
      final slot = (t.hour * 60 + t.minute) ~/ 5;
      slotVals.putIfAbsent(slot, () => []).add(v);

      if (v < 3.9) {
        if (epStart == null) {
          epStart = t;
          epPrev = t;
          epMin = v;
        } else if (t.difference(epPrev!).inMinutes.abs() <= 15) {
          epPrev = t;
          epMin = math.min(epMin, v);
        } else {
          closeEp();
          epStart = t;
          epPrev = t;
          epMin = v;
        }
      } else {
        closeEp();
      }
    }
    closeEp();

    final meanMg = sumMg / n;
    var sq = 0.0;
    for (final v in mgVals) {
      sq += (v - meanMg) * (v - meanMg);
    }
    final sd = math.sqrt(sq / n); // 总体标准差
    final slots = <int, SlotStat>{};
    for (final e in slotVals.entries) {
      e.value.sort();
      slots[e.key] = SlotStat.fromSorted(e.value);
    }
    double pct(int c) => c * 100.0 / n;
    return AgpStats(
      total: n,
      tir: pct(cTir),
      tbr1: pct(cTbr1),
      tbr2: pct(cTbr2),
      tar1: pct(cTar1),
      tar2: pct(cTar2),
      meanMmol: meanMg / mg,
      gmi: 3.31 + 0.02392 * meanMg,
      sd: sd,
      cv: meanMg > 0 ? sd / meanMg * 100 : 0,
      coverage: n / (days * 1440) * 100,
      episodes: episodes,
      slots: slots,
    );
  }
}

/// 一次低血糖事件（连续 <3.9 段）
class HypoEpisode {
  final DateTime start;
  final DateTime end;
  final double minMmol;
  const HypoEpisode(
      {required this.start, required this.end, required this.minMmol});

  /// 事件跨越的分钟数（起止同一分钟记 1，测试里 08:10→08:11 = 2）
  int get minutes => end.difference(start).inMinutes + 1;
}

/// 一个 5 分钟时间槽的分位数（全天 AGP 曲线用）
class SlotStat {
  final double p10, p25, median, p75, p90;
  final int count;
  const SlotStat({
    required this.p10,
    required this.p25,
    required this.median,
    required this.p75,
    required this.p90,
    required this.count,
  });

  factory SlotStat.fromSorted(List<double> sorted) {
    double q(double p) {
      if (sorted.isEmpty) return 0;
      final pos = p * (sorted.length - 1);
      final lo = pos.floor();
      final hi = pos.ceil();
      return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
    }

    return SlotStat(
      p10: q(0.10),
      p25: q(0.25),
      median: q(0.50),
      p75: q(0.75),
      p90: q(0.90),
      count: sorted.length,
    );
  }
}
