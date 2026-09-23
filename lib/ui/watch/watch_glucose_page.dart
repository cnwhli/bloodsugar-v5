import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/bg_sync.dart';
import '../../services/health_bridge.dart';
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
      });
      _buzzForLevel();
    }));
    _subs.add(_manager.stateStream.listen((s) {
      if (!mounted) return;
      setState(() => _scanState = s.toString().split('.').last);
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
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// 抬腕/回前台：血糖从库补最新，运动三件套刷一次——
  /// 手表表盘的"抬腕显示"本质就是 resumed 时立刻有数，不转菊花
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadLocal();
      _loadSport();
    }
  }

  /// 心率/步数/运动时长（三件套，失败就留空显示 --）
  Future<void> _loadSport() async {
    final r = await HealthBridge.readSportToday();
    if (!mounted) return;
    setState(() {
      _bpm = r.bpm;
      _steps = r.steps;
      _workoutMin = r.workoutMin;
    });
  }

  /// 先读本机库最新一条（手表独立用：自己扫自己存，不依赖手机）
  Future<void> _loadLocal() async {
    try {
      await AppDatabase.init();
      final rows = await AppDatabase.instance.recentReadings(limit: 1);
      if (!mounted) return;
      if (rows.isNotEmpty) {
        final ts = DateTime.tryParse('${rows.first['created_at'] ?? ''}');
        setState(() {
          _mmolL =
              (rows.first['value_mmol_l'] as num?)?.toDouble() ?? 0;
          _trend = (rows.first['trend'] as num?)?.toInt() ?? 0;
          _brand = '${rows.first['brand'] ?? ''}';
          if (ts != null) _updatedAt = ts;
          _hasData = _mmolL > 0;
        });
      }
    } catch (_) {}
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
    await _manager.startLowPowerWatch();
    if (mounted) setState(() => _lowPowerOn = true);
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
        child: _buildContent(statusColor: statusColor),
      ),
    );
  }

  Widget _buildContent({required Color statusColor}) {
    final big = widget.shape.isCircular ? 40.0 : 56.0;
    final small = widget.shape.isCircular ? 11.0 : 13.0;
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
        const SizedBox(height: 6),
        // 运动三件套：心率 / 步数 / 运动分钟（读不到显示 --，不断层）
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
