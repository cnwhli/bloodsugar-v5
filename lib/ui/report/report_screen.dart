import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/report/agp.dart';

/// AGP 血糖报告页（对标微泰/硅基/雅培官方报告，五步法结构）：
///
/// 1) 数据充分性：覆盖率 + 有效天数（<70% 提示数据不足，仅供参考）
/// 2) 整体达标：GMI、平均血糖、TIR 五分区条
/// 3) 低血糖风险：TBR 事件列表（时间、时长、最低值）
/// 4) 血糖波动：CV（>36% 高波动标红）
/// 5) 高血糖风险：TAR 时段分布（柱状：哪个时段高最多）
/// + AGP 全天曲线：中位线 + 25–75% 深色带 + 10–90% 浅色带（仿官方 AGP 图）
/// + 每日葡萄糖曲线：近 7 天迷你折线（找哪天最差）
/// + CSV 导出（全量，不止 50 条）
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  int _days = 14;
  bool _loading = true;
  AgpStats? _stats;
  List<(double, DateTime)> _rows = [];
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      await AppDatabase.init();
      final now = DateTime.now();
      final from = now.subtract(Duration(days: _days));
      final maps =
          await AppDatabase.instance.readingsBetween(from, now);
      final rows = <(double, DateTime)>[];
      for (final m in maps) {
        final v = (m['value_mmol_l'] as num?)?.toDouble();
        final t = DateTime.tryParse('${m['created_at']}');
        if (v != null && t != null) rows.add((v, t));
      }
      final recent =
          await AppDatabase.instance.recentReadings(limit: 50);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _stats = AgpStats.summarize(rows, days: _days);
        _recent = recent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载失败：$e')));
    }
  }

  Future<void> _exportCsv() async {
    if (_rows.isEmpty) return;
    final buf = StringBuffer('time,mmol_L,mg_dL\n');
    final sorted = List.of(_rows)..sort((a, b) => a.$2.compareTo(b.$2));
    for (final (v, t) in sorted) {
      buf.write('$t,${v.toStringAsFixed(1)},${(v * 18.0182).round()}\n');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${sorted.length} 条 CSV，可粘贴发给医生')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('血糖报告'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '导出 CSV（全量）',
            onPressed: _exportCsv,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _rangePicker(),
                  const SizedBox(height: 12),
                  if (_stats == null || _stats!.total == 0)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('该时段暂无记录，连接血糖仪后自动生成报告',
                            style: TextStyle(color: Colors.grey)),
                      ),
                    )
                  else ...[
                    _coverageCard(),
                    const SizedBox(height: 12),
                    _overviewCard(),
                    const SizedBox(height: 12),
                    _agpChart(),
                    const SizedBox(height: 12),
                    _hypoCard(),
                    const SizedBox(height: 12),
                    _tarByHourCard(),
                    const SizedBox(height: 12),
                    _dailyMiniCard(),
                    const SizedBox(height: 12),
                    _recentCard(),
                  ],
                ],
              ),
            ),
    );
  }

  // ---- 时间窗选择 ----
  Widget _rangePicker() {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 7, label: Text('7天')),
        ButtonSegment(value: 14, label: Text('14天')),
        ButtonSegment(value: 30, label: Text('30天')),
      ],
      selected: {_days},
      onSelectionChanged: (s) {
        setState(() => _days = s.first);
        _load();
      },
    );
  }

  // ---- ① 数据充分性 ----
  Widget _coverageCard() {
    final s = _stats!;
    final ok = s.coverage >= 70;
    // 有效天数：有 ≥1 条的天数
    final days = _rows.map((r) => DateTime(r.$2.year, r.$2.month, r.$2.day)).toSet().length;
    return Card(
      color: ok ? null : Colors.orange.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(ok ? Icons.check_circle : Icons.warning,
                color: ok ? Colors.green : Colors.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ok
                    ? '数据充分：$_days 天共 ${s.total} 条，覆盖率 ${s.coverage.toStringAsFixed(1)}%（有效 $days 天）'
                    : '数据不足：覆盖率仅 ${s.coverage.toStringAsFixed(1)}%（建议≥70%），结论仅供参考——保持 App 后台运行可补全',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- ② 整体达标：GMI/平均/TIR 五分区 ----
  Widget _overviewCard() {
    final s = _stats!;
    final tirOk = s.tir >= 70;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('整体达标情况',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _kpi('GMI', '${s.gmi.toStringAsFixed(1)}%', Colors.purple),
                _kpi('平均', '${s.meanMmol.toStringAsFixed(1)}', Colors.blue),
                _kpi('TIR', '${s.tir.toStringAsFixed(0)}%',
                    tirOk ? Colors.green : Colors.orange),
                _kpi('CV', '${s.cv.toStringAsFixed(0)}%',
                    s.cv <= 36 ? Colors.green : Colors.red),
              ],
            ),
            const SizedBox(height: 10),
            _fiveBar(),
            const SizedBox(height: 6),
            Text(
              '目标：TIR≥70% · TBR<4% · TAR<25% · CV≤36%（成人非妊娠，2023 共识）',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kpi(String label, String value, Color color) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        Text(value,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  /// 五分区横条：TBR2深蓝 / TBR1浅蓝 / TIR绿 / TAR1橙 / TAR2红
  Widget _fiveBar() {
    final s = _stats!;
    Widget seg(double pct, Color c, String tip) {
      if (pct <= 0) return const SizedBox.shrink();
      return Tooltip(
        message: tip,
        child: Container(
          width: double.infinity,
          height: 18,
          decoration: BoxDecoration(color: c),
          child: pct >= 8
              ? Center(
                  child: Text('${pct.toStringAsFixed(0)}%',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.white)))
              : null,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(
        children: [
          Expanded(
              flex: (s.tbr2 * 10).round().clamp(1, 1000),
              child: seg(s.tbr2, const Color(0xFF1A237E),
                  '很低 <3.0：${s.tbr2.toStringAsFixed(1)}%')),
          Expanded(
              flex: (s.tbr1 * 10).round().clamp(1, 1000),
              child: seg(s.tbr1, Colors.blue,
                  '低 3.0–3.8：${s.tbr1.toStringAsFixed(1)}%')),
          Expanded(
              flex: (s.tir * 10).round().clamp(1, 1000),
              child: seg(s.tir, Colors.green,
                  '范围内 3.9–10.0：${s.tir.toStringAsFixed(1)}%')),
          Expanded(
              flex: (s.tar1 * 10).round().clamp(1, 1000),
              child: seg(s.tar1, Colors.orange,
                  '高 10.1–13.9：${s.tar1.toStringAsFixed(1)}%')),
          Expanded(
              flex: (s.tar2 * 10).round().clamp(1, 1000),
              child: seg(s.tar2, Colors.red,
                  '很高 >13.9：${s.tar2.toStringAsFixed(1)}%')),
        ],
      ),
    );
  }

  // ---- AGP 全天曲线 ----
  Widget _agpChart() {
    final s = _stats!;
    if (s.slots.isEmpty) return const SizedBox.shrink();
    final med = <FlSpot>[];
    final q1 = <FlSpot>[];
    final q3 = <FlSpot>[];
    final p10 = <FlSpot>[];
    final p90 = <FlSpot>[];
    final keys = s.slots.keys.toList()..sort();
    for (final k in keys) {
      final st = s.slots[k]!;
      final x = k / 12.0; // 槽 → 小时
      med.add(FlSpot(x, st.median.clamp(0, 25)));
      q1.add(FlSpot(x, st.p25.clamp(0, 25)));
      q3.add(FlSpot(x, st.p75.clamp(0, 25)));
      p10.add(FlSpot(x, st.p10.clamp(0, 25)));
      p90.add(FlSpot(x, st.p90.clamp(0, 25)));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AGP 全天图谱（多天叠加）',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const Text('黑线中位 · 深带25–75% · 浅带10–90%',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            SizedBox(
              height: 220,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: 24,
                  minY: 0,
                  maxY: 15,
                  gridData: FlGridData(
                    drawVerticalLine: true,
                    getDrawingHorizontalLine: (v) => FlLine(
                      color: Colors.grey.withValues(alpha: 0.3),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        getTitlesWidget: (v, _) => Text(
                          v.toStringAsFixed(0),
                          style: const TextStyle(
                              fontSize: 10, color: Colors.grey),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 3,
                        getTitlesWidget: (v, _) => Text(
                          '${v.toInt()}:00',
                          style: const TextStyle(
                              fontSize: 10, color: Colors.grey),
                        ),
                      ),
                    ),
                    topTitles: AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  extraLinesData: ExtraLinesData(
                    horizontalLines: [
                      HorizontalLine(
                          y: 3.9, color: Colors.blue, strokeWidth: 1),
                      HorizontalLine(
                          y: 10.0, color: Colors.red, strokeWidth: 1),
                    ],
                  ),
                  lineBarsData: [
                    // 10–90% 浅带
                    LineChartBarData(
                      spots: p10,
                      isCurved: true,
                      barWidth: 0,
                      color: Colors.transparent,
                      dotData: FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blue.withValues(alpha: 0.10),
                        cutOffY: 0,
                        applyCutOffY: false,
                      ),
                    ),
                    LineChartBarData(
                      spots: p90,
                      isCurved: true,
                      barWidth: 0,
                      color: Colors.transparent,
                      dotData: FlDotData(show: false),
                    ),
                    // 25–75% 深带
                    LineChartBarData(
                      spots: q1,
                      isCurved: true,
                      barWidth: 0,
                      color: Colors.transparent,
                      dotData: FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blue.withValues(alpha: 0.22),
                        cutOffY: 0,
                        applyCutOffY: false,
                      ),
                    ),
                    LineChartBarData(
                      spots: q3,
                      isCurved: true,
                      barWidth: 0,
                      color: Colors.transparent,
                      dotData: FlDotData(show: false),
                    ),
                    // 中位线
                    LineChartBarData(
                      spots: med,
                      isCurved: true,
                      barWidth: 2.5,
                      color: Colors.black87,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- ③ 低血糖事件 ----
  Widget _hypoCard() {
    final s = _stats!;
    final eps = s.episodes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '低血糖事件（${eps.length} 次 · TBR ${s.tbr1.toStringAsFixed(1)}%+${s.tbr2.toStringAsFixed(1)}%）',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (eps.isEmpty)
              const Text('该时段无低血糖，好样的 👍',
                  style: TextStyle(color: Colors.green)),
            ...eps.take(10).map((e) => ListTile(
                  dense: true,
                  leading: Icon(
                    e.minMmol < 3.0
                        ? Icons.dangerous
                        : Icons.warning,
                    color: e.minMmol < 3.0 ? Colors.red : Colors.orange,
                  ),
                  title: Text(
                      '${_dt(e.start)} 起，约 ${e.minutes} 分钟，最低 ${e.minMmol.toStringAsFixed(1)} mmol/L'),
                  subtitle: Text(e.minMmol < 3.0
                      ? '2 级低血糖：需立即纠正'
                      : '1 级低血糖：注意复查'),
                )),
            if (eps.length > 10)
              Text('…还有 ${eps.length - 10} 次，导出 CSV 看全量',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ---- ⑤ 高血糖时段分布 ----
  Widget _tarByHourCard() {
    // 24 小时桶：统计 >10.0 的点在哪个小时最多
    final buckets = List<int>.filled(24, 0);
    for (final (v, t) in _rows) {
      if (v > 10.0) buckets[t.hour]++;
    }
    final maxV = buckets.fold<int>(0, (a, b) => a > b ? a : b);
    if (maxV == 0) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('高血糖时段：该时段无 >10.0 的点 👍',
              style: TextStyle(color: Colors.green)),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('高血糖时段分布（>10.0 的点按小时统计）',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: BarChart(
                BarChartData(
                  maxY: maxV.toDouble(),
                  gridData: FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 3,
                        getTitlesWidget: (v, _) => Text(
                          '${v.toInt()}h',
                          style: const TextStyle(
                              fontSize: 9, color: Colors.grey),
                        ),
                      ),
                    ),
                  ),
                  barGroups: List.generate(
                    24,
                    (h) => BarChartGroupData(
                      x: h,
                      barRods: [
                        BarChartRodData(
                          toY: buckets[h].toDouble(),
                          width: 8,
                          color: buckets[h] == maxV
                              ? Colors.red
                              : Colors.orange,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Text('最高峰：${buckets.indexOf(maxV)} 点前后（$maxV 个高点）——重点看这一餐的用药和饮食',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  // ---- 每日曲线（近 7 天迷你图） ----
  Widget _dailyMiniCard() {
    // 按天分组
    final byDay = <String, List<(double, DateTime)>>{};
    for (final r in _rows) {
      final k =
          '${r.$2.year}-${r.$2.month.toString().padLeft(2, '0')}-${r.$2.day.toString().padLeft(2, '0')}';
      byDay.putIfAbsent(k, () => []).add(r);
    }
    final days = byDay.keys.toList()..sort();
    final show = days.length > 7 ? days.sublist(days.length - 7) : days;
    if (show.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('每日曲线（近 7 天）',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            ...show.reversed.map((k) {
              final pts = byDay[k]!
                ..sort((a, b) => a.$2.compareTo(b.$2));
              final spots = <FlSpot>[];
              final t0 = pts.first.$2;
              for (final (v, t) in pts) {
                spots.add(FlSpot(
                    t.difference(t0).inMinutes.toDouble(),
                    v.clamp(0, 25)));
              }
              final dayTir = pts
                      .where((p) => p.$1 >= 3.9 && p.$1 <= 10.0)
                      .length /
                  pts.length *
                  100;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '$k · ${pts.length} 点 · TIR ${dayTir.toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 12)),
                    SizedBox(
                      height: 70,
                      child: LineChart(
                        LineChartData(
                          minY: 0,
                          maxY: 15,
                          gridData: FlGridData(show: false),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                                sideTitles:
                                    SideTitles(showTitles: false)),
                            rightTitles: AxisTitles(
                                sideTitles:
                                    SideTitles(showTitles: false)),
                            topTitles: AxisTitles(
                                sideTitles:
                                    SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(
                                sideTitles:
                                    SideTitles(showTitles: false)),
                          ),
                          borderData: FlBorderData(show: false),
                          extraLinesData: ExtraLinesData(
                            horizontalLines: [
                              HorizontalLine(
                                  y: 3.9,
                                  color: Colors.blue,
                                  strokeWidth: 1),
                              HorizontalLine(
                                  y: 10.0,
                                  color: Colors.red,
                                  strokeWidth: 1),
                            ],
                          ),
                          lineBarsData: [
                            LineChartBarData(
                              spots: spots,
                              isCurved: true,
                              barWidth: 1.5,
                              color: dayTir >= 70
                                  ? Colors.green
                                  : Colors.orange,
                              dotData: FlDotData(show: false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // ---- 最近记录 ----
  Widget _recentCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('最近记录',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            if (_recent.isEmpty)
              const Text('暂无记录，去首页录入或连接血糖仪',
                  style: TextStyle(color: Colors.grey)),
            ..._recent.take(20).map((r) => ListTile(
                  dense: true,
                  title: Text(
                    '${((r['value_mmol_l'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)} mmol/L',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                      '${r['brand'] ?? ''} · ${r['source'] ?? ''} · ${(r['created_at'] ?? '').toString().substring(0, 16)}'),
                )),
          ],
        ),
      ),
    );
  }

  String _dt(DateTime t) =>
      '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
