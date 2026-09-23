import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/bg_sync.dart';
import '../../services/health_bridge.dart';
import '../../domain/vitals/vital_types.dart';
import '../watch/multi_watch_arch.dart';

/// 手表端血糖页面（OPPO Watch X 优先，同时手机可预览）
/// 支持圆形/方形屏幕自适应
///
/// 数据来源（真实，非模拟）：
/// 1. 本机 BleCgmManager 单例（手机/手表都能单独连发射器——OPPO Watch X
///    是完整安卓，flutter_blue_plus 可直接在手表上扫 AiDEX 广播）；
/// 2. 本机数据库（手机收的数，手表装同包也能读到自己收的）；
/// 3. 官方血糖表盘走 Health Connect（见 HealthBridge），本页是自研表盘。
///
/// 手势（小屏无按钮，全靠手势）：
/// - 左右滑：数值 ↔ 历史曲线 ↔ 今日统计 三页切换
/// - 点一下数值页：手动刷新（库+运动三件套）
/// - 长按任意页：开始/停止监听
/// - 点一下曲线页：切换 3h / 6h / 12h / 24h 范围
///
/// 预警：低血糖 (<3.9) 蓝屏 + 重震 / 高血糖 (>10) 红屏 + 重震
class WatchGlucosePage extends StatefulWidget {
  final WatchShape shape; // 屏幕形状（圆形/方形）
  final String userId;

  const WatchGlucosePage({
    super.key,
    this.shape = WatchShape.rectangular,
    required this.userId,
  });

  @override
  State<WatchGlucosePage> createState() => _WatchGlucosePageState();
}

class _WatchGlucosePageState extends State<WatchGlucosePage>
    with WidgetsBindingObserver {
  final _manager = BleCgmManager();
  double _mmolL = 0;
  int _trend = 0;
  String _brand = '';
  DateTime _updatedAt = DateTime.now();
  bool _hasData = false;
  String _scanState = '';
  final List<StreamSubscription> _subs = [];
  // 运动三件套（从 Health Connect / 手表传感器读，读不到就显示 --）
  int? _bpm;
  int? _steps;
  int? _workoutMin;
  double? _spo2;
  String? _bp; // "120/80"
  String? _sleep; // "6小时30分"
  Timer? _sportTimer;

  // ---- 历史 + 手势状态 ----
  final _pager = PageController();
  int _page = 0;
  List<_Pt> _hist = []; // 时间正序
  int _rangeH = 6; // 曲线范围：3 / 6 / 12 / 24，点曲线切换
  // 扫描日志缓存（诊断页用：附近设备/权限/失败原因都在这）
  final List<String> _diagLogs = [];

  static const double _lowThreshold = 3.9;
  static const double _highThreshold = 10.0;

  bool get _lowAlert => _hasData && _mmolL < _lowThreshold;
  bool get _highAlert => _hasData && _mmolL > _highThreshold;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 抬腕/回前台即刷新
    _loadLocal();
    _loadSport(); // 心率/步数/运动
    // 运动数据 5 分钟刷一次（抬腕看的是缓存值，不转菊花）
    _sportTimer = Timer.periodic(
        const Duration(minutes: 5), (_) => _loadSport());
    // 实时订阅：新数进来表盘自动刷
    _subs.add(_manager.readingStream.listen((r) {
      if (!mounted) return;
      setState(() {
        _mmolL = r.valueMmolL;
        _trend = r.trend;
        _brand = r.brandLabel;
        _updatedAt = r.timestamp;
        _hasData = true;
        _hist.add(_Pt(r.valueMmolL, r.timestamp));
        if (_hist.length > 500) {
          _hist = _hist.sublist(_hist.length - 500);
        }
      });
      _buzzForLevel();
    }));
    _subs.add(_manager.stateStream.listen((s) {
      if (!mounted) return;
      setState(() => _scanState = s.toString().split('.').last);
    }));
    // 扫描日志缓存（诊断页最近 20 条：附近设备/权限/失败原因）
    _subs.add(_manager.logStream.listen((msg) {
      _diagLogs.add(msg);
      if (_diagLogs.length > 50) _diagLogs.removeAt(0);
    }));
    // 后台收数通知（手表息屏期间的数）：直接更新表盘，不用点开
    _subs.add(BgSync.stream.listen((msg) {
      if (!mounted) return;
      try {
        final parts = msg.split('|');
        final v = double.tryParse(parts[0]) ?? 0;
        if (v <= 0) return;
        setState(() {
          _mmolL = v;
          _trend = int.tryParse(parts[1]) ?? 0;
          _updatedAt =
              DateTime.tryParse(parts[2]) ?? DateTime.now();
          _hasData = true;
        });
        _buzzForLevel();
      } catch (_) {}
    }));
    setState(() => _scanState = _manager.state.toString().split('.').last);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sportTimer?.cancel();
    _pager.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// 抬腕/回前台：血糖从库补最新（含历史），运动三件套刷一次——
  /// 手表表盘的"抬腕显示"本质就是 resumed 时立刻有数，不转菊花
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadLocal();
      _loadSport();
    }
  }

  /// 心率/步数/运动时长/血氧/血压/睡眠（失败就留空显示 --）
  Future<void> _loadSport() async {
    final r = await HealthBridge.readTodaySnapshot();
    if (!mounted) return;
    setState(() {
      _bpm = r.bpm;
      _steps = r.steps;
      _workoutMin = r.workouts.isEmpty ? null : r.workoutMin;
      _spo2 = r.spo2;
      _bp = (r.systolic != null && r.diastolic != null)
          ? '${r.systolic}/${r.diastolic}'
          : null;
      _sleep = r.sleepMin != null ? formatSleep(r.sleepMin!) : null;
    });
  }

  /// 先读本机库最新一条 + 最近 24h 历史（手表独立用：自己扫自己存，不依赖手机）
  /// 本机库空时再读系统平台兜底（官方表盘/官方 App 写入的数），
  /// 兜底命中就显示它（时间戳按平台时间），并注明来源——
  /// 之前库空就直接 "--"，平台有数也看不见
  Future<void> _loadLocal() async {
    try {
      await AppDatabase.init();
      final rows = await AppDatabase.instance.recentReadings(limit: 1);
      final hist =
          await AppDatabase.instance.readingsLast24h(limit: 288);
      if (!mounted) return;
      final pts = <_Pt>[];
      for (final m in hist) {
        final v = (m['value_mmol_l'] as num?)?.toDouble();
        final t = DateTime.tryParse('${m['created_at'] ?? ''}');
        if (v != null && v > 0 && t != null) pts.add(_Pt(v, t));
      }
      setState(() {
        _hist = pts;
        if (rows.isNotEmpty) {
          final ts =
              DateTime.tryParse('${rows.first['created_at'] ?? ''}');
          _mmolL =
              (rows.first['value_mmol_l'] as num?)?.toDouble() ?? 0;
          _trend = (rows.first['trend'] as num?)?.toInt() ?? 0;
          _brand = '${rows.first['brand'] ?? ''}';
          if (ts != null) _updatedAt = ts;
          _hasData = _mmolL > 0;
        }
      });
      // 本机库空：读平台兜底（官方表盘/官方 App 写入的数），有就显示
      if (!_hasData || _hist.isEmpty) {
        final g = await HealthBridge.readLatestGlucose();
        if (g != null && mounted) {
          setState(() {
            _mmolL = g.mmolL;
            _updatedAt = g.time;
            _hasData = true;
            _brand = '系统平台';
            _hist.add(_Pt(g.mmolL, g.time));
          });
        }
      }
    } catch (_) {}
  }

  /// 点一下数值页：手动刷新
  Future<void> _manualRefresh() async {
    await _loadLocal();
    await _loadSport();
    if (!mounted) return;
    HapticFeedback.lightImpact();
  }

  Future<void> _toggleScan() async {
    if (_lowPowerOn) {
      await _manager.stopLowPowerWatch();
      setState(() => _lowPowerOn = false);
      return;
    }
    // 手表用省电监听：每分钟扫 15 秒（对齐发射器广播），其余休眠——
    // 手表电池小，不能像手机前台那样持续 lowLatency 扫描。
    // 参考各家 CGM 官方 App：都是按发射器 1 分钟 cadence 对齐唤醒，
    // 空闲时射频休眠，效果不丢、功耗降一个数量级。
    final err = await _manager.startLowPowerWatch();
    if (!mounted) return;
    setState(() => _lowPowerOn = err == null);
    // 失败直接显示原因（最常见：手表上没给"附近的设备"权限）——
    // 之前吞掉返回值，显示"监听中但没数"，误导人
    if (err != null) {
      setState(() => _scanState = err);
      HapticFeedback.heavyImpact();
    }
  }

  bool _lowPowerOn = false;

  Future<void> _buzzForLevel() async {
    if (_lowAlert || _highAlert) {
      // 低血糖三短震 / 高血糖两长震（用系统震动，手表端无需插件）
      final times = _lowAlert ? 3 : 2;
      for (var i = 0; i < times; i++) {
        HapticFeedback.heavyImpact();
        await Future.delayed(
            Duration(milliseconds: _lowAlert ? 400 : 700));
      }
    } else {
      HapticFeedback.lightImpact();
    }
  }

  String _fmtTime(DateTime ts) {
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String _fmtHM(DateTime ts) {
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  // ---- 历史范围过滤 ----
  List<_Pt> get _ranged {
    if (_hist.isEmpty) return const [];
    final cut =
        DateTime.now().subtract(Duration(hours: _rangeH));
    return _hist.where((p) => p.t.isAfter(cut)).toList();
  }

  void _cycleRange() {
    setState(() {
      _rangeH = _rangeH == 3
          ? 6
          : _rangeH == 6
              ? 12
              : _rangeH == 12
                  ? 24
                  : 3;
    });
    HapticFeedback.selectionClick();
  }

  /// 数据新鲜度：超过 10 分钟没数就提示
  String? get _staleTip {
    if (!_hasData) return null;
    final min = DateTime.now().difference(_updatedAt).inMinutes;
    if (min >= 10) return '数据 $min 分钟前，可能断连';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _lowAlert
        ? Colors.blue
        : _highAlert
            ? Colors.red
            : Colors.green;

    return Scaffold(
      backgroundColor: Colors.black,
      body: WatchAdaptiveLayout(
        shape: widget.shape,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: PageView(
                controller: _pager,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  // 第 1 页：当前值（点一下刷新，长按监听开关）
                  GestureDetector(
                    onTap: _manualRefresh,
                    onLongPress: () async {
                      HapticFeedback.heavyImpact();
                      await _toggleScan();
                    },
                    child: _buildContent(statusColor: statusColor),
                  ),
                  // 第 2 页：历史曲线（点一下切换范围，长按监听开关）
                  GestureDetector(
                    onTap: _cycleRange,
                    onLongPress: () async {
                      HapticFeedback.heavyImpact();
                      await _toggleScan();
                    },
                    child: _buildHistoryPage(),
                  ),
                  // 第 3 页：今日统计（点一下刷新，长按监听开关）
                  GestureDetector(
                    onTap: _manualRefresh,
                    onLongPress: () async {
                      HapticFeedback.heavyImpact();
                      await _toggleScan();
                    },
                    child: _buildStatsPage(statusColor),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 页点 + 手势提示
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                3,
                (i) => Container(
                  width: 6,
                  height: 6,
                  margin:
                      const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _page == i
                        ? Colors.white
                        : Colors.white24,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _page == 0
                  ? '点一下刷新 · 长按${_lowPowerOn ? '停止' : '开始'}监听 · 右滑看历史'
                  : _page == 1
                      ? '点曲线切范围(${_rangeH}h) · 长按${_lowPowerOn ? '停止' : '开始'}监听'
                      : '点一下刷新 · 长按${_lowPowerOn ? '停止' : '开始'}监听',
              style:
                  const TextStyle(fontSize: 9, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent({required Color statusColor}) {
    final big = widget.shape.isCircular ? 40.0 : 56.0;
    final small = widget.shape.isCircular ? 11.0 : 13.0;
    final stale = _staleTip;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 预警横幅
        if (_lowAlert || _highAlert) ...[
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: _lowAlert ? Colors.blue : Colors.red,
              borderRadius: BorderRadius.circular(
                  widget.shape.isCircular ? 16 : 8),
            ),
            child: Text(
              _lowAlert ? '⚠️ 低血糖' : '⚠️ 高血糖',
              style: TextStyle(
                color: Colors.white,
                fontSize: small + 2,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        // 血糖值
        Text(
          _hasData ? _mmolL.toStringAsFixed(1) : '--',
          style: TextStyle(
            fontSize: big,
            fontWeight: FontWeight.bold,
            color: statusColor,
          ),
        ),
        Text(
          _hasData
              ? '${(_mmolL * 18.0182).toStringAsFixed(0)} mg/dL'
              : '暂无数据',
          style: TextStyle(fontSize: small, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Text(
          _trendLabel(_trend),
          style: TextStyle(
              fontSize: small + 4, color: statusColor),
        ),
        const SizedBox(height: 2),
        Text(
          _hasData
              ? '$_brand · ${_fmtTime(_updatedAt)}'
              : '点下方按钮开始监听',
          style: TextStyle(fontSize: small, color: Colors.grey),
        ),
        if (stale != null) ...[
          const SizedBox(height: 2),
          Text(stale,
              style: TextStyle(
                  fontSize: small - 1, color: Colors.orange)),
        ],
        const SizedBox(height: 6),
        // 健康六件套：心率 / 步数 / 运动分钟 / 血氧 / 血压 / 睡眠
        // （读不到显示 --，不断层）
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _sportItem('❤', _bpm == null ? '--' : '$_bpm',
                'bpm', small),
            _sportItem('👣', _fmtSteps(_steps), '步', small),
            _sportItem('🏃', _workoutMin == null ? '--' : '$_workoutMin',
                '分钟', small),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _sportItem('🩸', _spo2 == null ? '--' : _spo2!.toStringAsFixed(0),
                '%血氧', small),
            _sportItem('💓', _bp ?? '--', '血压', small),
            _sportItem('😴', _sleep ?? '--', '睡眠', small),
          ],
        ),
        const SizedBox(height: 8),
        // 手表独立监听开关（OPPO Watch X 可脱离手机单收广播）
        OutlinedButton.icon(
          onPressed: _toggleScan,
          icon: Icon(
            _lowPowerOn
                ? Icons.bluetooth_disabled
                : Icons.bluetooth_searching,
            size: 16,
          ),
          label: Text(
            _lowPowerOn
                ? '停止监听（省电模式·每分钟收一次）'
                : '手表监听',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// 第 2 页：历史曲线（最近 _rangeH 小时，超限红点，点一下切范围）
  Widget _buildHistoryPage() {
    final small = widget.shape.isCircular ? 10.0 : 12.0;
    final pts = _ranged;
    if (pts.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 24),
          const Text('--',
              style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          Text('近 $_rangeH 小时无数据\n点一下切换范围',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: small, color: Colors.grey)),
        ],
      );
    }
    double mn = pts.first.v, mx = pts.first.v, sum = 0;
    var low = 0, high = 0;
    for (final p in pts) {
      if (p.v < mn) mn = p.v;
      if (p.v > mx) mx = p.v;
      sum += p.v;
      if (p.v < _lowThreshold) {
        low++;
      } else if (p.v > _highThreshold) {
        high++;
      }
    }
    final avg = sum / pts.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('近 $_rangeH 小时 · ${pts.length} 点',
            style: TextStyle(fontSize: small, color: Colors.grey)),
        const SizedBox(height: 4),
        SizedBox(
          height: widget.shape.isCircular ? 110 : 150,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparkPainter(
              pts: pts,
              low: _lowThreshold,
              high: _highThreshold,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_fmtHM(pts.first.t),
                style:
                    TextStyle(fontSize: small - 1, color: Colors.grey)),
            Text(_fmtHM(pts.last.t),
                style:
                    TextStyle(fontSize: small - 1, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '最高 ${mx.toStringAsFixed(1)} · 平均 ${avg.toStringAsFixed(1)} · 最低 ${mn.toStringAsFixed(1)}',
          style: TextStyle(fontSize: small - 1, color: Colors.white70),
        ),
        Text(
          low + high == 0
              ? '全部在范围内 👍'
              : '偏低 $low 点 · 偏高 $high 点',
          style: TextStyle(
              fontSize: small - 1,
              color: low + high == 0 ? Colors.green : Colors.orange),
        ),
      ],
    );
  }

  /// 第 3 页：今日统计（TIR/计数/低血糖次数 + 快捷按钮）
  Widget _buildStatsPage(Color statusColor) {
    final small = widget.shape.isCircular ? 10.0 : 12.0;
    final now = DateTime.now();
    final today =
        _hist.where((p) => p.t.day == now.day && p.t.month == now.month).toList();
    String tir = '--';
    var lowN = 0, highN = 0;
    if (today.isNotEmpty) {
      final inR =
          today.where((p) => p.v >= 3.9 && p.v <= 10.0).length;
      tir = '${(inR / today.length * 100).toStringAsFixed(0)}%';
      lowN = today.where((p) => p.v < 3.9).length;
      highN = today.where((p) => p.v > 10.0).length;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('今日 · ${today.length} 点',
            style: TextStyle(fontSize: small, color: Colors.grey)),
        const SizedBox(height: 6),
        Text(tir,
            style: TextStyle(
                fontSize: widget.shape.isCircular ? 36 : 48,
                fontWeight: FontWeight.bold,
                color: statusColor)),
        Text('TIR 今日',
            style: TextStyle(fontSize: small, color: Colors.grey)),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _statMini('偏低', '$lowN', Colors.blue, small),
            _statMini('偏高', '$highN', Colors.red, small),
            _statMini('db总数', '${_hist.length}', Colors.white70, small),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          // 显示扫描状态原文（权限缺失/蓝牙没开/扫失败直接可见，
          // 不再是干巴巴的"未监听"）
          _lowPowerOn ? '监听中 · $_scanState' : '$_scanState',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: small - 1, color: Colors.grey),
        ),
        const SizedBox(height: 4),
        // 诊断按钮：点一下看扫描日志（附近设备/权限/失败原因都在这）
        GestureDetector(
          onTap: () => _showDiagSheet(),
          child: Text(
            '诊断日志 · 点我查看',
            style: TextStyle(
                fontSize: small - 1,
                color: Colors.blue,
                decoration: TextDecoration.underline),
          ),
        ),
      ],
    );
  }

  /// 手表诊断页：一页纸说清"为什么没数"
  /// - 蓝牙开关 / 本机库条数 / 平台兜底 / 最近 20 条扫描日志
  /// - 出问题先看这页，截屏发我就能定位
  Future<void> _showDiagSheet() async {
    var dbCount = -1;
    String? platInfo;
    try {
      await AppDatabase.init();
      final rows = await AppDatabase.instance.recentReadings(limit: 1000);
      dbCount = rows.length;
    } catch (_) {}
    try {
      final g = await HealthBridge.readLatestGlucose();
      platInfo = g == null
          ? '平台无血糖数据'
          : '平台有数 ${g.mmolL.toStringAsFixed(1)} · ${_fmtTime(g.time)}';
    } catch (_) {
      platInfo = '平台读取失败';
    }
    final logs = _diagLogs.length > 20
        ? _diagLogs.sublist(_diagLogs.length - 20)
        : List.of(_diagLogs);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('诊断',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 6),
              Text('状态：$_scanState',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70)),
              Text(
                  dbCount < 0 ? '本机库：读取失败' : '本机库：$dbCount 条',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70)),
              Text('平台兜底：${platInfo ?? '未知'}',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70)),
              const SizedBox(height: 6),
              const Text('最近日志：',
                  style: TextStyle(
                      fontSize: 12, color: Colors.white70)),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    logs.isEmpty ? '(暂无日志)' : logs.join('\n'),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statMini(String label, String v, Color c, double fs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(v,
            style: TextStyle(
                fontSize: fs + 6,
                fontWeight: FontWeight.bold,
                color: c)),
        Text(label,
            style: TextStyle(fontSize: fs - 1, color: Colors.grey)),
      ],
    );
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

  /// 运动小项：图标 + 值 + 单位（值读不到显示 --）
  Widget _sportItem(
      String icon, String value, String unit, double fontSize) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: TextStyle(fontSize: fontSize + 2)),
        Text(value,
            style: TextStyle(
                fontSize: fontSize + 4,
                fontWeight: FontWeight.bold,
                color: Colors.white)),
        Text(unit,
            style:
                TextStyle(fontSize: fontSize - 1, color: Colors.grey)),
      ],
    );
  }

  /// 步数格式化：12345 → 1.2万
  String _fmtSteps(int? steps) {
    if (steps == null) return '--';
    if (steps >= 10000) {
      return '${(steps / 10000).toStringAsFixed(1)}万';
    }
    return '$steps';
  }
}

class _Pt {
  final double v;
  final DateTime t;
  const _Pt(this.v, this.t);
}

/// 手表小屏火花线：绿线 + 超限红点 + 3.9/10.0 虚线（省电 CustomPaint，不用 fl_chart）
class _SparkPainter extends CustomPainter {
  final List<_Pt> pts;
  final double low, high;
  const _SparkPainter(
      {required this.pts, required this.low, required this.high});

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.length < 2) return;
    const maxV = 15.0;
    double x(int i) =>
        size.width * i / (pts.length - 1).clamp(1, 1 << 30);
    double y(double v) =>
        size.height - (v.clamp(0, maxV) / maxV) * size.height;
    final dash = Paint()
      ..color = const Color(0xFF616161)
      ..strokeWidth = 1;
    // 阈值虚线
    for (final t in [low, high]) {
      final yy = y(t);
      var xx = 0.0;
      while (xx < size.width) {
        canvas.drawLine(Offset(xx, yy), Offset(xx + 4, yy), dash);
        xx += 8;
      }
    }
    // 主线
    final line = Paint()
      ..color = const Color(0xFF34C759)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path()..moveTo(x(0), y(pts.first.v));
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(x(i), y(pts[i].v));
    }
    canvas.drawPath(path, line);
    // 超限红点
    final dot = Paint()..color = const Color(0xFFFF3B30);
    for (var i = 0; i < pts.length; i++) {
      if (pts[i].v < low || pts[i].v > high) {
        canvas.drawCircle(Offset(x(i), y(pts[i].v)), 2.5, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.pts.length != pts.length ||
      (old.pts.isNotEmpty &&
          pts.isNotEmpty &&
          old.pts.last.v != pts.last.v);
}
