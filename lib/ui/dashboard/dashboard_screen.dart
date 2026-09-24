import 'dart:async';

import 'package:flutter/material.dart';
import 'package:bloodsugar_v5/services/bg_sync.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../domain/vitals/vital_types.dart';
import '../../services/health_bridge.dart';
import '../../services/phone_widget.dart';
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
  // 健康快照（首页健康卡片：自动同步优先，手动补兜底）
  HealthSnapshot _snap = const HealthSnapshot();
  List<Map<String, dynamic>> _todayLogs = [];
  // Health Connect 状态：null=未检测，false=没装（芯片点一下跳安装）
  bool? _hcOk;

  @override
  void initState() {
    super.initState();
    _loadLatest();
    // 新数进来首页自动刷：数值+时间+曲线+周统计一起更新，不用手动下拉
    _readingSub =
        BleCgmManager().readingStream.listen((_) => _loadLatest());
    // 后台收数通知：退后台期间的数进来，首页数值+曲线自动补上
    _bgSub = BgSync.stream.listen((_) {
      if (mounted) _loadLatest();
    });
  }

  StreamSubscription<String>? _bgSub;

  @override
  void dispose() {
    _readingSub?.cancel(); // 只取消订阅，manager 常驻
    _bgSub?.cancel();
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
        // 桌面小组件同步推（心率/步数用当前快照的，有就带上）
        PhoneWidget.push(
          mmolL: _currentGlucose,
          trendLabel: _trend,
          time: _latestTime,
          bpm: _snap.bpm,
          steps: _snap.steps,
        );
      }
    });
    final stats = await AppDatabase.instance.weeklyStats();
    if (mounted) setState(() => _stats = stats);
    // 健康快照 + 今日记录（首页健康卡片用；失败留空显示 --，不挡血糖）
    try {
      final hcOk = await HealthBridge.isAvailable();
      if (mounted) setState(() => _hcOk = hcOk);
      if (!hcOk) {
        // 没装 Health Connect：芯片留 --，点一下跳安装（国产手机常没预装）
        if (mounted) {
          final logs = await AppDatabase.instance.todayTreatments();
          if (mounted) setState(() => _todayLogs = logs);
        }
      } else {
        final snap = await HealthBridge.readTodaySnapshot();
        final logs = await AppDatabase.instance.todayTreatments();
        if (mounted) {
          setState(() {
            _snap = snap;
            _todayLogs = logs;
          });
          // 自动同步进 vitals 表（换手机/云同步时有底；每天一条快照，去重靠 kind+date）
          _cacheSnapshot(snap);
          // 自动同步失败的项，用今天手动补的数兜底（source=manual，不冒充自动）
          _fillFromManual();
        }
      }
    } catch (_) {}
  }

  /// 快照进 vitals 表：有数的项才存，source=health（和手动补的 manual 区分）
  Future<void> _cacheSnapshot(HealthSnapshot s) async {
    try {
      final db = AppDatabase.instance;
      if (s.bpm != null) {
        await db.insertVital(
            kind: 'heart_rate',
            value1: s.bpm!.toDouble(),
            unit: 'bpm',
            source: 'health');
      }
      if (s.spo2 != null) {
        await db.insertVital(
            kind: 'spo2', value1: s.spo2, unit: '%', source: 'health');
      }
      if (s.systolic != null && s.diastolic != null) {
        await db.insertVital(
            kind: 'bp',
            value1: s.systolic!.toDouble(),
            value2: s.diastolic!.toDouble(),
            unit: 'mmHg',
            source: 'health');
      }
      if (s.sleepMin != null) {
        await db.insertVital(
            kind: 'sleep',
            value1: s.sleepMin!.toDouble(),
            unit: 'min',
            source: 'health');
      }
      if (s.steps != null) {
        await db.insertVital(
            kind: 'steps',
            value1: s.steps!.toDouble(),
            unit: '步',
            source: 'health');
      }
      if (s.weightKg != null) {
        await db.insertVital(
            kind: 'weight',
            value1: s.weightKg,
            unit: 'kg',
            source: 'health');
      }
      for (final w in s.workouts) {
        await db.insertVital(
          kind: 'workout',
          value1: w.minutes.toDouble(),
          unit: 'min',
          source: 'health',
          device: workoutLabel(w.type),
        );
      }
    } catch (_) {}
  }

  /// 快捷手动补：从首页今日健康卡片的芯片点进来。
  /// kind：heart_rate（单值）/ spo2（单值）/ bp（收缩+舒张）/ sleep（小时）/ steps（单值）
  /// 存 source=manual，今天的手动只兜底今天（todayVital），不污染自动数。
  Future<void> _quickManual(
      BuildContext context, String kind, String label, String unit) async {
    final v1Ctrl = TextEditingController();
    final v2Ctrl = TextEditingController();
    final isBp = kind == 'bp';
    final isSleep = kind == 'sleep';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('手动补$label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: v1Ctrl,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              decoration: InputDecoration(
                labelText: isBp
                    ? '收缩压（mmHg）'
                    : isSleep
                        ? '睡眠（小时，如 6.5）'
                        : '$label（$unit）',
                border: const OutlineInputBorder(),
              ),
            ),
            if (isBp) ...[
              const SizedBox(height: 12),
              TextField(
                controller: v2Ctrl,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                  labelText: '舒张压（mmHg）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text('没戴手表/设备没数时手填；戴了设备以自动同步为准。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final v1 = double.tryParse(v1Ctrl.text.trim());
      if (v1 == null || v1 <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('数值不对，再看看')));
        }
        return;
      }
      if (isBp) {
        final v2 = double.tryParse(v2Ctrl.text.trim());
        if (v2 == null || v2 <= 0) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('舒张压不对，再看看')));
          }
          return;
        }
        await AppDatabase.instance.insertVital(
            kind: 'bp', value1: v1, value2: v2, unit: 'mmHg');
      } else if (isSleep) {
        await AppDatabase.instance.insertVital(
            kind: 'sleep', value1: v1 * 60, unit: 'min');
      } else {
        await AppDatabase.instance.insertVital(
            kind: kind, value1: v1, unit: unit);
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已补$label')));
        _loadLatest(); // 刷新后卡片从 -- 变成刚填的数
      }
    } catch (_) {}
  }

  /// 快捷记运动：从今日健康卡片点进来，直接进记一笔的运动页
  void _quickExercise(BuildContext context) {
    Navigator.pushNamed(context, '/log')
        .then((_) => _loadLatest());
  }

  /// 自动同步缺项，用"今天手动补的数"兜底显示。
  /// 优先级：health（手表/系统平台自动）> manual（今天手填）。
  /// 昨天的手动数不冒充今天（todayVital 只查当天）。
  /// 每项只在自动失败（snap 为 null）时才读手动，避免覆盖自动数。
  Future<void> _fillFromManual() async {
    try {
      final db = AppDatabase.instance;
      var bpm = _snap.bpm;
      var spo2 = _snap.spo2;
      var sys = _snap.systolic;
      var dia = _snap.diastolic;
      var sleepMin = _snap.sleepMin;
      var steps = _snap.steps;
      var weight = _snap.weightKg;
      double? num1(Map<String, dynamic>? m) =>
          (m?['value1'] as num?)?.toDouble();
      if (bpm == null) {
        bpm = num1(await db.todayVital('heart_rate'))?.round();
      }
      if (spo2 == null) {
        spo2 = num1(await db.todayVital('spo2'));
      }
      if (sys == null || dia == null) {
        final m = await db.todayVital('bp');
        if (m != null) {
          sys = num1(m)?.round();
          dia = (m['value2'] as num?)?.toDouble().round();
        }
      }
      if (sleepMin == null) {
        sleepMin = num1(await db.todayVital('sleep'))?.round();
      }
      if (steps == null) {
        steps = num1(await db.todayVital('steps'))?.round();
      }
      if (weight == null) {
        weight = num1(await db.todayVital('weight'));
      }
      if (!mounted) return;
      setState(() {
        _snap = HealthSnapshot(
          bpm: bpm,
          restingHr: _snap.restingHr,
          spo2: spo2,
          systolic: sys,
          diastolic: dia,
          weightKg: weight,
          steps: steps,
          sleepMin: sleepMin,
          walkRunKm: _snap.walkRunKm,
          swimKm: _snap.swimKm,
          cycleKm: _snap.cycleKm,
          caloriesKcal: _snap.caloriesKcal,
          workouts: _snap.workouts,
        );
      });
    } catch (_) {}
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
              // 顶部大数值卡片（仿微泰/硅基：大数字 + mg/dL + 趋势箭头 + 时间）
              Card(
                color: _statusColor.withValues(alpha: 0.12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 16, horizontal: 12),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceEvenly,
                    children: [
                      // 左：大数值 + 单位
                      Column(
                        children: [
                          Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.baseline,
                            textBaseline:
                                TextBaseline.alphabetic,
                            children: [
                              Text(
                                _currentGlucose > 0
                                    ? _currentGlucose
                                        .toStringAsFixed(1)
                                    : '--',
                                style: TextStyle(
                                  fontSize: 56,
                                  fontWeight: FontWeight.bold,
                                  color: _statusColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'mmol/L',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: _statusColor),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _currentGlucose > 0
                                ? '${(_currentGlucose * 18.0182).toStringAsFixed(0)} mg/dL'
                                : '',
                            style: const TextStyle(
                                fontSize: 13,
                                color: Colors.grey),
                          ),
                        ],
                      ),
                      // 右：趋势 + 范围状态 + 时间
                      Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(_trend,
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: _statusColor)),
                          const SizedBox(height: 4),
                          Text(
                            _currentGlucose <= 0
                                ? ''
                                : _currentGlucose < 3.9
                                    ? '● 偏低'
                                    : _currentGlucose > 10.0
                                        ? '● 偏高'
                                        : '● 范围内',
                            style: TextStyle(
                                fontSize: 14,
                                color: _statusColor),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _latestTime.isNotEmpty
                                ? '更新于 $_latestTime'
                                : '',
                            style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

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
              const SizedBox(height: 16),

              // 桌面小组件（一键钉到桌面：血糖+心率步数，不开 App 也能看）
              Card(
                child: ListTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: const Text('桌面小组件'),
                  subtitle: const Text('血糖大数字放手机桌面，点一下进 App'),
                  trailing: FilledButton.tonal(
                    onPressed: () async {
                      final ok =
                          await PhoneWidget.isPinSupported();
                      if (!context.mounted) return;
                      if (ok) {
                        await PhoneWidget.requestPin();
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                                '长按手机桌面空白处 → 添加小组件 → 选“血糖管家”即可'),
                            duration: Duration(seconds: 5),
                          ),
                        );
                      }
                    },
                    child: const Text('加到桌面'),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 今日健康（自动同步优先 + 手动补兜底；对标欧态健康 App 的一站式数据）
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
                          const Text('今日健康',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold)),
                          TextButton(
                            onPressed: () => Navigator.pushNamed(
                                context, '/log'),
                            child: const Text('记一笔 →'),
                          ),
                        ],
                      ),
                      const Text('手表/手环戴上自动同步；没戴就点一下芯片手填',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey)),
                      if (_hcOk == false)
                        GestureDetector(
                          onTap: () async {
                            await HealthBridge.installPrompt();
                            if (mounted) _loadLatest();
                          },
                          child: const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              '⚠️ 未装 Health Connect，点这里安装后自动同步（国产手机常没预装）',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.orange),
                            ),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // 能点：-- 的芯片点一下直接手填，有数的点一下可覆盖修正
                          _healthChip(
                              '❤',
                              _snap.bpm == null
                                  ? '--'
                                  : '${_snap.bpm} bpm',
                              '心率',
                              onTap: () => _quickManual(
                                  context, 'heart_rate', '心率', 'bpm')),
                          _healthChip(
                              '🩸',
                              _snap.spo2 == null
                                  ? '--'
                                  : '${_snap.spo2!.toStringAsFixed(0)}%',
                              '血氧',
                              onTap: () => _quickManual(
                                  context, 'spo2', '血氧', '%')),
                          _healthChip(
                              '💓',
                              (_snap.systolic == null ||
                                      _snap.diastolic == null)
                                  ? '--'
                                  : '${_snap.systolic}/${_snap.diastolic}',
                              '血压',
                              onTap: () => _quickManual(
                                  context, 'bp', '血压', 'mmHg')),
                          _healthChip(
                              '😴',
                              _snap.sleepMin == null
                                  ? '--'
                                  : formatSleep(_snap.sleepMin!),
                              '睡眠',
                              onTap: () => _quickManual(
                                  context, 'sleep', '睡眠', '小时')),
                          _healthChip(
                              '👣',
                              _snap.steps == null
                                  ? '--'
                                  : '${_snap.steps}步',
                              '步数',
                              onTap: () => _quickManual(
                                  context, 'steps', '步数', '步')),
                          _healthChip(
                              '🏃',
                              _snap.workouts.isEmpty
                                  ? '--'
                                  : _snap.workouts
                                      .map((w) =>
                                          '${workoutLabel(w.type)}${w.minutes}分')
                                      .join(' · '),
                              '运动',
                              onTap: () => _quickExercise(context)),
                        ],
                      ),
                      if (_todayLogs.isNotEmpty) ...[
                        const Divider(height: 20),
                        const Text('今日记录',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        for (final m in _todayLogs.take(5))
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 2),
                            child: Text(
                              '• ${_fmtTreatmentRow(m)}',
                              style:
                                  const TextStyle(fontSize: 13),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
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
                  _navButton(Icons.edit_note, '记一笔', '/log'),
                  _navButton(Icons.people, '糖友微信群', '/community'),
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
              style: TextStyle(color: Colors.grey, fontSize: 13)));
    }
    final spots = <FlSpot>[];
    // X 轴用真实时间（相对首点的分钟数）：断连的空档会在曲线上留出缺口——
    // 仿微泰/硅基官方 App：横轴是时间，点与点按真实间隔排
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
    // 范围内点/范围外点分色：官方 App 都是正常段绿、高低段变色
    final inSpots = <FlSpot>[];
    final outSpots = <FlSpot>[];
    for (final s in spots) {
      if (s.y < 3.9 || s.y > 10.0) {
        outSpots.add(s);
      } else {
        inSpots.add(s);
      }
    }
    // ignore: unused_local_variable
    final lineColor =
        _statusColor == Colors.grey ? Colors.green : _statusColor;
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        // 点一下曲线看具体数值+时间（仿官方 App 点查）
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touched) => touched
                .map((t) => LineTooltipItem(
                      '${t.y.toStringAsFixed(1)} mmol/L\n${_axisTime(_chartT0.add(Duration(minutes: t.x.toInt())).toString())}',
                      const TextStyle(fontSize: 12),
                    ))
                .toList(),
          ),
        ),
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
          // 主线：范围内绿色段
          LineChartBarData(
            spots: inSpots.isEmpty ? spots : inSpots,
            isCurved: true,
            barWidth: 2.5,
            color: Colors.green,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.green.withValues(alpha: 0.15),
            ),
          ),
          // 叠加线：超范围点红色标出（仿官方 App 高低段变色）
          if (outSpots.isNotEmpty)
            LineChartBarData(
              spots: outSpots,
              isCurved: false,
              barWidth: 0,
              color: Colors.red,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, _, __, ___) =>
                    FlDotCirclePainter(
                  radius: 4,
                  color: Colors.red,
                  strokeWidth: 1,
                  strokeColor: Colors.white,
                ),
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
      onPressed: () => Navigator.pushNamed(context, route).then((_) {
        // 从子页返回后刷新（记录/读数可能变了）
        if (mounted) _loadLatest();
      }),
      icon: Icon(icon),
      label: Text(label),
    );
  }

  /// 健康小芯片：图标 + 值 + 指标名（可点：没自动数时点一下手填）
  Widget _healthChip(String icon, String value, String label,
      {VoidCallback? onTap}) {
    final inner = Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$icon $value',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold)),
          Text(label,
              style:
                  const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
    if (onTap == null) return inner;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: inner,
    );
  }

  /// treatments 行 → 展示文案（dashboard 轻量拼装，不引 domain/logs）
  String _fmtTreatmentRow(Map<String, dynamic> m) {
    final detail = '${m['detail'] ?? ''}';
    final amount = (m['amount'] as num?)?.toDouble();
    final unit = '${m['unit'] ?? ''}';
    final extra = '${m['extra'] ?? ''}';
    var head = detail;
    if (amount != null) {
      final num = amount == amount.roundToDouble()
          ? '${amount.toInt()}'
          : '$amount';
      head = head.isEmpty ? '$num$unit' : '$head $num$unit';
    }
    final parts = <String>[];
    if (head.isNotEmpty) parts.add(head);
    if (extra.isNotEmpty) parts.add(extra);
    return parts.isEmpty ? '一条记录' : parts.join(' · ');
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
