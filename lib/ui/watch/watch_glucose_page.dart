import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/bg_sync.dart';
import '../../services/health_bridge.dart';
import '../../services/cloud_sync.dart';
import '../../services/watch_sensors.dart';
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
/// 手表小屏交互（v2 重做：之前 Column 写死高度，按钮被挤出屏幕看不见）：
/// - 整页 SingleChildScrollView：内容再多也能滑到按钮
/// - PageView 三页：数值 ↔ 历史 ↔ 统计，左右滑切换
/// - 点数值页：手动刷新；大按钮≥48px：监听开关/范围切换，手指好点
/// - 长按任意页：开始/停止监听（备用手势）
/// - 诊断日志折叠在数值页底部，展开看"附近：xxx"/失败原因
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
  Timer? _sportTimer;
  StreamSubscription? _hrSub; // 心率实时流订阅（dispose 随 _subs 一起取消）

  // ---- 分页 + 历史 ----
  final _pager = PageController();
  int _page = 0;
  List<_Pt> _hist = []; // 最近历史（时间正序，供曲线+列表）
  int _rangeH = 6; // 历史页范围：3/6/12/24
  int _longDays = 7; // 统计页范围：7/14/30
  ({int n, double tir, double avg, double mn, double mx, int low, int high})?
      _longStats;
  bool _longLoading = false;
  // 扫描日志（诊断折叠页用）
  final List<String> _diagLogs = [];
  bool _showDiag = false;

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
    // 扫描日志缓存（诊断折叠页：附近设备/权限/失败原因都在这）
    _subs.add(_manager.logStream.listen((msg) {
      _diagLogs.add(msg);
      if (_diagLogs.length > 50) _diagLogs.removeAt(0);
      if (_showDiag && mounted) setState(() {});
    }));
    // 后台收数通知（手表息屏期间的数）：直接更新表盘，不用点开
    _subs.add(BgSync.stream.listen((msg) {
      if (!mounted) return;
      try {
        final d = BgSync.decode(msg);
        if (d == null) return;
        setState(() {
          _mmolL = d.v;
          _trend = d.trend;
          _updatedAt = d.ts;
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

  /// 心率/步数/运动时长。数据源优先级：
  /// 1. 硬件直读（WatchSensors：OPPO Watch X 自带心率+计步硬件，不经过
  ///    Health Connect/欢太健康，国产表唯一走得通的链路）；
  /// 2. Health Connect 兜底（运动分钟等硬件给不了的项）。
  /// 先查 Health Connect 装没装：没装直接标不可用，不让用户干等 --。
  Future<void> _loadSport() async {
    // 硬件直读先行：要权限 → 一次读最新值（只补 Health Connect 没有的项，
    // Health Connect 有数时以它为准，不覆盖）
    try {
      await WatchSensors.ensurePermission();
      final v = await WatchSensors.latest();
      if (!mounted) return;
      setState(() {
        if (v.bpm != null) _bpm = v.bpm;
        if (v.steps != null) _steps = v.steps;
      });
      // 直读心率入库（source=ble，和手动/Health区分）+ 推云端：
      // 手表连表测到的心跳，手机登录同一账号秒级看到，反之亦然。
      // 1 分钟最多记一条（传感器 1Hz 回调，不能每跳都写库）。
      if (v.bpm != null) _cacheHr(v.bpm!);
      if (v.steps != null) _cacheSteps(v.steps!);
    } catch (_) {}
    // 心率实时流：只订阅一次（重复进 _loadSport 不重复订阅）
    try {
      if (_hrSub == null) {
        _hrSub = WatchSensors.heartRateStream().listen((bpm) {
          if (!mounted) return;
          setState(() => _bpm = bpm);
          _cacheHr(bpm);
        });
        _subs.add(_hrSub!);
      }
    } catch (_) {}
    final ok = await HealthBridge.isAvailable();
    if (!ok) {
      // 没装 Health Connect：硬件直读的数照样显示，运动分钟记一笔手填
      return;
    }
    final r = await HealthBridge.readSportToday();
    if (!mounted) return;
    setState(() {
      // Health Connect 有数才覆盖，没数保留硬件直读的值
      if (r.bpm != null) _bpm = r.bpm;
      if (r.steps != null) _steps = r.steps;
      _workoutMin = r.workoutMin;
    });
  }

  /// 直读心率入库 + 推云：1 分钟最多一条（传感器回调频繁，不能每跳写库）。
  /// source=ble，和手动（manual）/Health Connect（health）区分开。
  DateTime _lastHrCache = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _cacheHr(int bpm) async {
    final now = DateTime.now();
    if (now.difference(_lastHrCache).inSeconds < 60) return;
    _lastHrCache = now;
    try {
      await AppDatabase.init();
      final id = await AppDatabase.instance.insertVital(
        kind: 'heart_rate',
        value1: bpm.toDouble(),
        unit: 'bpm',
        source: 'ble',
        device: '手表直读',
        recordedAt: now,
      );
      await CloudSync.pushVital(
        localId: id,
        kind: 'heart_rate',
        value1: bpm.toDouble(),
        unit: 'bpm',
        source: 'ble',
        device: '手表直读',
        measuredAt: now,
      );
    } catch (_) {}
  }

  /// 直读步数入库 + 推云：1 小时最多一条（计步器是累计值，记快照即可）。
  DateTime _lastStepsCache = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _cacheSteps(int steps) async {
    final now = DateTime.now();
    if (now.difference(_lastStepsCache).inMinutes < 60) return;
    _lastStepsCache = now;
    try {
      await AppDatabase.init();
      final id = await AppDatabase.instance.insertVital(
        kind: 'steps',
        value1: steps.toDouble(),
        unit: '步',
        source: 'ble',
        device: '手表直读',
        recordedAt: now,
      );
      await CloudSync.pushVital(
        localId: id,
        kind: 'steps',
        value1: steps.toDouble(),
        unit: '步',
        source: 'ble',
        device: '手表直读',
        measuredAt: now,
      );
    } catch (_) {}
  }

  /// 先读本机库最新一条 + 最近历史（手表独立用：自己扫自己存，不依赖手机）
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
      _loadLongTerm();
    } catch (_) {}
  }

  Future<void> _toggleScan() async {
    if (_lowPowerOn) {
      await _manager.disconnect();
      if (mounted) setState(() => _lowPowerOn = false);
      return;
    }
    // 手表直连：和手机端一样的持续监听（continuous+lowLatency，无 timeout）。
    // 之前手表用 Timer 每分钟唤起扫 20 秒的省电轮询，在这块安卓手表上
    // burst 根本起不来（日志只有"省电监听"提示、从无"附近："设备），
    // 而昨天早上的手机端持续监听是可以的——先保证连上，费电以后再优化。
    final err = await _manager.startScan();
    if (!mounted) return;
    setState(() {
      _lowPowerOn = err == null;
      if (err != null) _scanState = err; // 失败直接显示原因，不假装监听中
    });
    if (err != null) {
      HapticFeedback.heavyImpact();
    }
  }

  bool _lowPowerOn = false;

  /// 点历史页切换范围
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

  /// 点统计页切换范围
  void _cycleLongRange() {
    setState(() {
      _longDays = _longDays == 7 ? 14 : _longDays == 14 ? 30 : 7;
      _longStats = null;
    });
    HapticFeedback.selectionClick();
    _loadLongTerm();
  }

  /// 长期统计（走本机库：手表自己收的 + CSV 补的，全在这）
  Future<void> _loadLongTerm() async {
    if (_longLoading) return;
    _longLoading = true;
    try {
      await AppDatabase.init();
      final now = DateTime.now();
      final rows = await AppDatabase.instance.readingsBetween(
        now.subtract(Duration(days: _longDays)),
        now,
      );
      if (!mounted) return;
      if (rows.isEmpty) {
        setState(() => _longStats = null);
        return;
      }
      var inR = 0, low = 0, high = 0, sum = 0.0;
      var mn = double.infinity, mx = double.negativeInfinity;
      for (final m in rows) {
        final v = (m['value_mmol_l'] as num?)?.toDouble() ?? 0;
        if (v <= 0) continue;
        sum += v;
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        if (v >= 3.9 && v <= 10.0) {
          inR++;
        } else if (v < 3.9) {
          low++;
        } else {
          high++;
        }
      }
      final n = rows.length;
      setState(() => _longStats = (
        n: n,
        tir: n == 0 ? 0 : inR / n * 100,
        avg: n == 0 ? 0 : sum / n,
        mn: mn.isInfinite ? 0 : mn,
        mx: mx.isInfinite ? 0 : mx,
        low: low,
        high: high,
      ));
    } catch (_) {
      if (mounted) setState(() => _longStats = null);
    } finally {
      _longLoading = false;
    }
  }

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

  /// 手表抬腕看的日期时间：9月24日 周三 15:40
  String _fmtDateTime(DateTime ts) {
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    final w = week[(ts.weekday - 1).clamp(0, 6)];
    return '${ts.month}月${ts.day}日 周$w ${_fmtHM(ts)}';
  }

  /// 手动重刷运动数据（点数值页即刷；Health Connect 没装时只刷硬件直读）
  Future<void> _refreshSport() async {
    await _loadSport();
    if (!mounted) return;
    HapticFeedback.lightImpact();
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
      body: SafeArea(
        child: WatchAdaptiveLayout(
          shape: widget.shape,
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _pager,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    // 第 1 页：数值（点一下刷新血糖+运动，长按开关监听）
                    GestureDetector(
                      onTap: () async {
                        await _loadLocal();
                        await _refreshSport();
                      },
                      onLongPress: () async {
                        HapticFeedback.heavyImpact();
                        await _toggleScan();
                      },
                      child: SingleChildScrollView(
                        child: _buildValuePage(
                            statusColor: statusColor),
                      ),
                    ),
                    // 第 2 页：历史（点一下切范围，长按开关监听）
                    GestureDetector(
                      onTap: _cycleRange,
                      onLongPress: () async {
                        HapticFeedback.heavyImpact();
                        await _toggleScan();
                      },
                      child: SingleChildScrollView(
                        child: _buildHistoryPage(),
                      ),
                    ),
                    // 第 3 页：统计（点一下切 7/14/30，长按开关监听）
                    GestureDetector(
                      onTap: _cycleLongRange,
                      onLongPress: () async {
                        HapticFeedback.heavyImpact();
                        await _toggleScan();
                      },
                      child: SingleChildScrollView(
                        child: _buildStatsPage(statusColor),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // 页点：3 个点，当前页高亮
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
                      color: i == _page
                          ? Colors.white
                          : Colors.white24,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
            ],
          ),
        ),
      ),
    );
  }

  /// 第 1 页：大数值 + 监听大按钮 + 诊断折叠
  Widget _buildValuePage({required Color statusColor}) {
    // 血糖数字调小（用户反馈太大把下面内容挤出屏），心率/步数卡片置顶放大。
    final big = widget.shape.isCircular ? 30.0 : 38.0;
    final small = widget.shape.isCircular ? 11.0 : 13.0;
    final logs = _diagLogs.length > 10
        ? _diagLogs.sublist(_diagLogs.length - 10)
        : List.of(_diagLogs);
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
        // 血糖值（调小：之前 40/56 把心率步数挤出屏看不到）
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
              ? '${(_mmolL * 18.0182).toStringAsFixed(0)} mg/dL ${_trendLabel(_trend)}'
              : '暂无数据',
          style: TextStyle(fontSize: small, color: Colors.grey),
        ),
        const SizedBox(height: 2),
        // 日期时间（手表抬腕先看今天几号几点，不用退回表盘）
        GestureDetector(
          onTap: () => setState(() {}), // 点一下刷新时间（抬腕常亮不准时手动刷）
          child: Text(
            _fmtDateTime(DateTime.now()),
            style: TextStyle(fontSize: small + 2, color: Colors.white70),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _hasData
              ? '$_brand · ${_fmtTime(_updatedAt)}'
              : '点下方按钮开始监听',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: small, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        // 心率/步数卡片：放大置顶（用户主要看心跳，之前被挤出屏）。
        // 有数白字，无数灰字 --，一眼看出传感器通没通。
        Container(
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _sportItem('❤', _bpm == null ? '--' : '$_bpm', 'bpm',
                  small + 2, dim: _bpm == null),
              _sportItem('👣', _fmtSteps(_steps), '步', small + 2,
                  dim: _steps == null),
              _sportItem('🏃', _workoutMin == null ? '--' : '$_workoutMin',
                  '分钟', small + 2,
                  dim: _workoutMin == null),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 手表独立监听大按钮（≥48px，小屏一定点得到）
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: _toggleScan,
            icon: Icon(
              _lowPowerOn
                  ? Icons.bluetooth_disabled
                  : Icons.bluetooth_searching,
              size: 20,
            ),
            label: Text(
              _lowPowerOn ? '停止监听' : '手表监听',
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _lowPowerOn ? '监听中 · $_scanState' : _scanState,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: small - 1, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        // 诊断折叠：点一下展开最近 10 条日志
        GestureDetector(
          onTap: () => setState(() => _showDiag = !_showDiag),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _showDiag ? '收起诊断日志 ▲' : '诊断日志 · 点我查看 ▼',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: small, color: Colors.blue),
            ),
          ),
        ),
        if (_showDiag) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              logs.isEmpty ? '暂无日志：还没开始扫描' : logs.join('\n'),
              style: const TextStyle(
                  fontSize: 10, color: Colors.white70),
            ),
          ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  /// 第 2 页：历史曲线 + 最近 8 条（点一下切 3/6/12/24h）
  Widget _buildHistoryPage() {
    final small = widget.shape.isCircular ? 10.0 : 12.0;
    final cut =
        DateTime.now().subtract(Duration(hours: _rangeH));
    final pts = _hist.where((p) => p.t.isAfter(cut)).toList();
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
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: _cycleRange,
              child: const Text('切换范围', style: TextStyle(fontSize: 15)),
            ),
          ),
        ],
      );
    }
    double mn = pts.first.v, mx = pts.first.v, sum = 0;
    for (final p in pts) {
      if (p.v < mn) mn = p.v;
      if (p.v > mx) mx = p.v;
      sum += p.v;
    }
    final avg = sum / pts.length;
    final tail = pts.length > 8 ? pts.sublist(pts.length - 8) : pts;
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
        const SizedBox(height: 6),
        // 最近 8 条列表（时间 + 数值，一行一条）
        ...tail.reversed.map((p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtTime(p.t),
                      style: TextStyle(
                          fontSize: small, color: Colors.grey)),
                  Text(p.v.toStringAsFixed(1),
                      style: TextStyle(
                          fontSize: small + 2,
                          fontWeight: FontWeight.bold,
                          color: p.v < _lowThreshold
                              ? Colors.blue
                              : p.v > _highThreshold
                                  ? Colors.red
                                  : Colors.white)),
                ],
              ),
            )),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(
            onPressed: _cycleRange,
            child: Text('范围 $_rangeH 小时 · 点我切换',
                style: const TextStyle(fontSize: 15)),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// 第 3 页：长期统计（点一下切 7/14/30 天）
  Widget _buildStatsPage(Color statusColor) {
    final small = widget.shape.isCircular ? 10.0 : 12.0;
    final s = _longStats;
    if (s == null && !_longLoading) {
      Future.microtask(_loadLongTerm);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('长期 · 近 $_longDays 天',
            style: TextStyle(fontSize: small, color: Colors.grey)),
        const SizedBox(height: 6),
        if (s == null)
          Text(_longLoading ? '…' : '--',
              style: TextStyle(
                  fontSize: widget.shape.isCircular ? 36 : 48,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey))
        else
          Text('${s.tir.toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: widget.shape.isCircular ? 36 : 48,
                  fontWeight: FontWeight.bold,
                  color: s.tir >= 70 ? Colors.green : Colors.orange)),
        Text('TIR $_longDays 天',
            style: TextStyle(fontSize: small, color: Colors.grey)),
        const SizedBox(height: 6),
        if (s != null) ...[
          Text(
            '平均 ${s.avg.toStringAsFixed(1)} · 最高 ${s.mx.toStringAsFixed(1)} · 最低 ${s.mn.toStringAsFixed(1)}',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: small - 1, color: Colors.white70),
          ),
          Text(
            '${s.n} 点 · 偏低 ${s.low} · 偏高 ${s.high}',
            style: TextStyle(
                fontSize: small - 1,
                color: s.low + s.high == 0
                    ? Colors.green
                    : Colors.orange),
          ),
        ] else
          Text(_longLoading ? '查库中…' : '暂无数据',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: small - 1, color: Colors.grey)),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton(
            onPressed: _cycleLongRange,
            child: Text('近 $_longDays 天 · 点我切换',
                style: const TextStyle(fontSize: 15)),
          ),
        ),
        const SizedBox(height: 4),
        Text('左右滑切换数值/历史/统计',
            style: TextStyle(fontSize: small - 1, color: Colors.grey)),
        const SizedBox(height: 12),
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
      String icon, String value, String unit, double fontSize,
      {bool dim = false}) {
    final vColor = dim ? Colors.white38 : Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: TextStyle(fontSize: fontSize + 2)),
        Text(value,
            style: TextStyle(
                fontSize: fontSize + 6,
                fontWeight: FontWeight.bold,
                color: vColor)),
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
  _Pt(this.v, this.t);
}

/// 火花线：血糖曲线 + 3.9/10.0 阈值虚线
class _SparkPainter extends CustomPainter {
  final List<_Pt> pts;
  final double low;
  final double high;
  _SparkPainter({required this.pts, required this.low, required this.high});

  @override
  void paint(Canvas canvas, Size size) {
    if (pts.isEmpty) return;
    var mn = pts.first.v, mx = pts.first.v;
    for (final p in pts) {
      if (p.v < mn) mn = p.v;
      if (p.v > mx) mx = p.v;
    }
    mn = (mn - 1).clamp(0, 30);
    mx = (mx + 1).clamp(mn + 2, 30);
    double y(double v) =>
        size.height - (v - mn) / (mx - mn) * size.height;
    double x(int i) =>
        pts.length == 1 ? size.width / 2 : i / (pts.length - 1) * size.width;

    final dash = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (final th in [low, high]) {
      if (th < mn || th > mx) continue;
      final yy = y(th);
      for (var dx = 0.0; dx < size.width; dx += 6) {
        canvas.drawLine(Offset(dx, yy), Offset(dx + 3, yy), dash);
      }
    }

    final line = Paint()
      ..color = Colors.green
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final p = Offset(x(i), y(pts[i].v));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(path, line);
    // 超限红点
    final dot = Paint()..color = Colors.red;
    for (var i = 0; i < pts.length; i++) {
      if (pts[i].v < low || pts[i].v > high) {
        canvas.drawCircle(Offset(x(i), y(pts[i].v)), 2.5, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.pts.length != pts.length ||
      (pts.isNotEmpty &&
          old.pts.isNotEmpty &&
          old.pts.last.v != pts.last.v);
}
