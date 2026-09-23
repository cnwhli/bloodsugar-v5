import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../ble/glucose_overlay.dart';

/// 首页仪表盘
/// 血糖圆环 + 24小时曲线 + 周统计 + 快捷操作
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double _currentGlucose = 0;
  String _trend = '--';
  Color _statusColor = Colors.grey;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _history = [];
  String _latestTime = ''; // 最新读数时间（你要的"血糖时间"）
  DateTime _chartT0 = DateTime.now(); // 曲线首点时间（横轴刻度反推用）
  StreamSubscription<GlucoseReading>? _readingSub;

  @override
  void initState() {
    super.initState();
    _loadLatest();
    // 新数进来首页自动刷：数值+时间+曲线+周统计一起更新，不用手动下拉
    _readingSub =
        BleCgmManager().readingStream.listen((_) => _loadLatest());
  }

  @override
  void dispose() {
    _readingSub?.cancel(); // 只取消订阅，manager 常驻
    super.dispose();
  }

  Future<void> _loadLatest() async {
    await AppDatabase.init();
    // 最近 24 小时曲线（最多 288 点，按时间正序）
    final history =
        await AppDatabase.instance.readingsLast24h(limit: 288);
    final latest = await AppDatabase.instance.recentReadings(limit: 1);
    if (!mounted) return;
    setState(() {
      _history = history;
      if (history.isNotEmpty) {
        _chartT0 = DateTime.tryParse(
                '${history.first['created_at'] ?? ''}') ??
            DateTime.now();
      }
      if (latest.isNotEmpty) {
        _currentGlucose =
            (latest.first['value_mmol_l'] as num?)?.toDouble() ?? 0;
        _trend = _trendLabel(
            (latest.first['trend'] as num?)?.toInt() ?? 0);
        _statusColor = _statusColorFor(_currentGlucose);
        _latestTime = _fmtDbTime('${latest.first['created_at'] ?? ''}');
        // 首页也同步推悬浮窗（蓝牙页开了悬浮窗后退回首页仍更新）
        GlucoseOverlay.push(_currentGlucose,
            (latest.first['trend'] as num?)?.toInt() ?? 0, _latestTime);
      }
    });
    final stats = await AppDatabase.instance.weeklyStats();
    if (mounted) setState(() => _stats = stats);
  }

  String _trendLabel(int trend) {
    switch (trend) {
      case 0:
        return '→ 平';
      case 1:
        return '↗ 慢升';
      case 2:
        return '↗ 快升';
      case 3:
        return '↘ 慢降';
      case 4:
        return '↘ 快降';
      default:
        return '--';
    }
  }

  Color _statusColorFor(double mmolL) {
    if (mmolL <= 0) return Colors.grey;
    if (mmolL < 3.9) return Colors.blue;
    if (mmolL > 10.0) return Colors.red;
    return Colors.green;
  }

  /// 数据库时间 "YYYY-MM-DD HH:MM:SS" → 今天显示 HH:MM:SS，跨天显示 MM-DD HH:MM
  String _fmtDbTime(String s) {
    if (s.isEmpty) return '';
    try {
      final ts = DateTime.parse(s);
      final now = DateTime.now();
      final hh = ts.hour.toString().padLeft(2, '0');
      final mm = ts.minute.toString().padLeft(2, '0');
      final ss = ts.second.toString().padLeft(2, '0');
      if (ts.year == now.year &&
          ts.month == now.month &&
          ts.day == now.day) {
        return '$hh:$mm:$ss';
      }
      return '${ts.month.toString().padLeft(2, '0')}-'
          '${ts.day.toString().padLeft(2, '0')} $hh:$mm';
    } catch (_) {
      return s.length >= 19 ? s.substring(5, 19) : s;
    }
  }

  /// 曲线横轴时间刻度：只取 HH:MM
  String _axisTime(String s) {
    try {
      final ts = DateTime.parse(s);
      return '${ts.hour.toString().padLeft(2, '0')}:'
          '${ts.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return s.length >= 19 ? s.substring(11, 16) : s;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('血糖管家')),
      body: RefreshIndicator(
        onRefresh: _loadLatest,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // 血糖圆环
              CircleAvatar(
                radius: 80,
                backgroundColor: _statusColor.withValues(alpha: 0.15),
                child: Center(
                  child: Text(
                    _currentGlucose > 0
                        ? _currentGlucose.toStringAsFixed(1)
                        : '--',
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: _statusColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(_trend, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 4),
              Text(
                _currentGlucose > 0
                    ? '${(_currentGlucose * 18.0182).toStringAsFixed(0)} mg/dL'
                    : '',
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
              // 最新读数时间
              if (_latestTime.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '更新于 $_latestTime',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey),
                  ),
                ),
              const SizedBox(height: 16),

              // 24 小时曲线
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('24 小时曲线',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold)),
                          Text('${_history.length} 个点',
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                          height: 180, child: _buildChart()),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 周统计卡片
              if (_stats != null &&
                  ((_stats!['total'] as int?) ?? 0) > 0)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _statCard(
                        'TIR', '${_stats!['tir']}%', Colors.green),
                    _statCard(
                        '平均',
                        '${((_stats!['avg'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}',
                        Colors.blue),
                    _statCard(
                        '最高',
                        '${((_stats!['max'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}',
                        Colors.red),
                    _statCard(
                        '最低',
                        '${((_stats!['min'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}',
                        Colors.orange),
                  ],
                ),
              const SizedBox(height: 24),

              // 快捷操作
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _navButton(Icons.bluetooth, '连接血糖仪', '/ble'),
                  _navButton(Icons.add_circle, '手动录入', '/add'),
                  _navButton(Icons.people, '社区', '/community'),
                  _navButton(Icons.smart_toy, 'AI 助手', '/ai-assistant'),
                  _navButton(
                      Icons.medical_services, '泵配对', '/pump-pair'),
                  _navButton(Icons.send, '手动给药', '/manual-bolus'),
                  _navButton(Icons.show_chart, '报告', '/report'),
                  _navButton(Icons.watch, '手表显示', '/watch'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChart() {
    if (_history.length < 2) {
      return const Center(
        child: Text('数据不足两点，连接血糖仪后自动绘制',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
      );
    }
    final spots = <FlSpot>[];
    // X 轴用真实时间（相对首点的分钟数）：断连的空档会在曲线上留出缺口，
    // 刻度也是从真实时间反推的——这才是"按时间显示"，之前是按序号画的
    final parsed = <DateTime>[];
    for (final r in _history) {
      parsed.add(DateTime.tryParse('${r['created_at'] ?? ''}') ??
          DateTime.now());
    }
    final t0 = parsed.first;
    for (var i = 0; i < _history.length; i++) {
      final v =
          (_history[i]['value_mmol_l'] as num?)?.toDouble() ?? 0;
      final xMin = parsed[i].difference(t0).inMinutes.toDouble();
      spots.add(FlSpot(xMin < 0 ? 0 : xMin, v.clamp(0, 25)));
    }
    final maxY = (spots.map((s) => s.y).reduce((a, b) => a > b ? a : b))
        .clamp(12.0, 25.0);
    final maxX = spots.last.x <= 0 ? 60.0 : spots.last.x;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            color: Colors.grey.withValues(alpha: 0.3),
            strokeWidth: 1,
            dashArray: v == 3.9 || v == 10.0 ? [5, 4] : null,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(0),
                style:
                    const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: 1,
              getTitlesWidget: (v, meta) {
                final n = _history.length;
                if (n < 2) return const SizedBox.shrink();
                // 按真实时间反推 v 分钟对应的刻度（头部/中部/尾部各一个）
                final show = v == meta.min ||
                    v == meta.max ||
                    (v - (meta.min + meta.max) / 2).abs() <
                        (meta.max - meta.min) / 6 + 1;
                if (!show) return const SizedBox.shrink();
                final t = _axisTime(_chartT0
                    .add(Duration(minutes: v.toInt()))
                    .toString());
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.grey),
                  ),
                );
              },
            ),
          ),
          topTitles:
              AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
          LineChartBarData(
            spots: spots,
            isCurved: true,
            barWidth: 2.5,
            color: _statusColor == Colors.grey
                ? Colors.blue
                : _statusColor,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: (_statusColor == Colors.grey
                      ? Colors.blue
                      : _statusColor)
                  .withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(label,
                style:
                    TextStyle(color: Colors.grey[600], fontSize: 12)),
            Text(value,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: color)),
          ],
        ),
      ),
    );
  }

  Widget _navButton(IconData icon, String label, String route) {
    return ElevatedButton.icon(
      onPressed: () => Navigator.pushNamed(context, route),
      icon: Icon(icon),
      label: Text(label),
    );
  }

  Widget _actionButton(
      IconData icon, String label, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: () {
        onTap();
        // 从子页返回后刷新（读数/设置可能变了）
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) _loadLatest();
        });
      },
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
