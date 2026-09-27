import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/datasource/local_db.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/bg_sync.dart';
import '../../services/health_bridge.dart';
import '../../services/cloud_sync.dart';
import '../../services/watch_sensors.dart';
import '../ble/cgm_foreground_service.dart';
import '../watch/multi_watch_arch.dart'
    hide CgmBrand, CgmBrandManager; // 旧手表架构占位枚举（和真协议同名，隐藏掉）

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
  Timer? _linkWatchdog; // 断链看门狗：5 分钟无新数 → 震动提醒 + 自动重扫
  DateTime _lastDataAt = DateTime.now();
  bool _linkLostBuzzed = false;

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

  // ---- 按设备分页：几个发射器就几个数值页 ----
  // key = 品牌 · 发射器（如"微泰 AiDEX · 22FJV7J"），和手机蓝牙页同口径。
  final Map<String, _Dev> _devs = {};
  List<String> get _devKeys => _devs.keys.toList();
  // 数值页 + 历史 + 统计总页数（没数时 1 数值页 + 历史 + 统计 = 3）
  int get _pageCount => (_devKeys.isEmpty ? 1 : _devKeys.length) + 2;
  String _devKeyOf(String brand, String sensor) =>
      sensor.isEmpty ? brand : '$brand · $sensor';
  // 已用天数：只有分钟序号口径的品牌才算（微泰 AiDEX 全系：广播
  // minFromStart 就是启动分钟数）。硅基 seq 非分钟口径不算，返回 null
  // 不显示——瞎报一天比不报更坏。
  int? _useDaysOf(String brandName, int? seq) {
    if (seq == null || seq < 0) return null;
    final b = brandName.toLowerCase();
    final isAidex = b.contains('aidex') ||
        b.contains('aidexx') ||
        b.contains('aidexlinx') ||
        b.contains('microtech');
    if (!isAidex) return null;
    return seq ~/ 1440;
  }
  // 库里 brand 是显示名（如"微泰 AiDEX 二代"），反查回 CgmBrand.name
  // 给 _useDaysOf 判分钟口径用；查不到原样返回（中文名也含 aidex 关键字时
  // _useDaysOf 照样认，不误杀）。
  // 注意：multi_watch_arch.dart 里有个同名旧 CgmBrand（手表架构占位，
  // 已在 import 里 hide 掉），这里用的是真协议枚举，别用错。
  String _brandNameOf(String label) {
    try {
      for (final b in CgmBrand.values) {
        if (b.displayName == label) return b.name;
      }
    } catch (_) {}
    return label;
  }
  // 图例/行内短名：只留发射器尾段（如 22FJV7J），防圆屏挤爆
  String _shortDev(String dev) {
    final i = dev.indexOf('·');
    final s = i >= 0 ? dev.substring(i + 1).trim() : dev;
    return s.length > 8 ? '…${s.substring(s.length - 8)}' : s;
  }

  // 多设备配色（数值大字 + 历史曲线同色，一眼对上）
  static const _devPalette = [
    Colors.green,
    Colors.cyan,
    Colors.orange,
    Colors.purple,
    Colors.yellow,
  ];
  Color _devColor(String key) {
    final i = _devKeys.indexOf(key);
    return _devPalette[(i < 0 ? 0 : i) % _devPalette.length];
  }

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
    // 实时订阅：新数进来 → 归到对应设备页 + 表盘自动刷 + 推云
    _subs.add(_manager.readingStream.listen((r) async {
      if (!mounted) return;
      _lastDataAt = DateTime.now(); // 看门狗喂食：有数=链路活着
      _linkLostBuzzed = false;
      // 先推云再刷 UI：手表直连时手机秒级看到，不用手动点同步
      try {
        if (CloudSync.isReady && CloudSync.loggedIn) {
          await AppDatabase.init();
          final id =
              await AppDatabase.instance.latestReadingId(r);
          await CloudSync.pushReading(
            localId: id,
            mmolL: r.valueMmolL,
            trend: r.trend,
            brand: r.brandLabel,
            source: 'ble',
            seq: r.minFromStart,
            sensorId: r.sensorId,
            measuredAt: r.timestamp,
          );
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        // 主快照保持最新一条（兼容旧逻辑/预警震动）
        _mmolL = r.valueMmolL;
        _trend = r.trend;
        _brand = r.brandLabel;
        _updatedAt = r.timestamp;
        _hasData = true;
        // 按设备归档：哪个发射器的数进哪个数值页
        final key = _devKeyOf(r.brandLabel, r.sensorId);
        _devs[key] = _Dev(r.valueMmolL, r.trend, r.brandLabel,
            r.timestamp, _useDaysOf(r.brand.name, r.minFromStart));
        _hist.add(_Pt(r.valueMmolL, r.timestamp, key));
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
    // 附近设备变化 → 选设备区重刷（节流 10 秒，manager 侧已节流）
    _subs.add(_manager.seenDevicesStream.listen((_) {
      if (!mounted) return;
      if (_watchDevsOpen) setState(() {}); // 展开时才刷，折叠只看 summary
    }));
    // 后台收数通知（手表息屏期间的数）：归到对应设备页，不用点开
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
          // BgSync 透了 sensorId：后台的数也归到发射器自己的页
          final key = _devKeyOf('', d.sensorId);
          final old = _devs[key];
          if (old == null) {
            _devs[key] =
                _Dev(d.v, d.trend, _devKeyOf('', d.sensorId), d.ts);
          } else {
            old.v = d.v;
            old.trend = d.trend;
            old.ts = d.ts;
          }
          _hist.add(_Pt(d.v, d.ts, key));
          if (_hist.length > 500) {
            _hist = _hist.sublist(_hist.length - 500);
          }
        });
        _buzzForLevel();
      } catch (_) {}
    }));
    setState(() => _scanState = _manager.state.toString().split('.').last);
    // 手表直连的前提：白名单 + 数据源必须先恢复，否则默认自动模式
    // 全品牌见谁连谁，硅基 LT 没被锁定时重连通道绕过去乱连别的。
    // 之前手表压根没调这两个 load，手机锁了 LT、手表还在自动乱连。
    // initState 非 async：fire-and-forget（load 完之前点的监听走旧值，
    // 进页面 1 秒内就完成，不影响）。
    _manager.loadSelectedDevices().catchError((_) {});
    _manager.loadSelectedBrands().catchError((_) {});
    // 手机→手表下行：登录后订阅 Realtime，手机收的数秒级到手表入库+
    // 归到对应设备页。之前手表只订阅了「上传」，没订阅「下行」——
    // 这就是"手机手表做不到实时同步"的病根之二。
    _startWatchCloudSub();
    // 断链看门狗：每分钟查一次，5 分钟没新数 → 长震提醒 + 自动重连。
    // 灭屏被杀后开屏进来就能发现，不用用户猜“是不是断了”。
    _linkWatchdog =
        Timer.periodic(const Duration(minutes: 1), (_) => _checkLink());
  }

  /// 手表侧 Realtime 下行：手机上传 → 手表秒级入库 + 归设备页 + 刷 UI。
  /// 登录/配对码登录后调用；重复进 initState 不重复订阅。
  /// 没登录/断网静默跳过（手表独立直连照样用，不绑死云）。
  bool _watchSubOn = false;
  Future<void> _startWatchCloudSub() async {
    if (_watchSubOn || !CloudSync.isReady || !CloudSync.loggedIn) return;
    _watchSubOn = true;
    try {
      await CloudSync.subscribeRealtime(
        onGlucose: (mmolL, trend, ts, sensorId, brand) {
          if (!mounted) return;
          _lastDataAt = DateTime.now();
          _linkLostBuzzed = false;
          setState(() {
            _mmolL = mmolL;
            _trend = trend;
            _updatedAt = ts;
            _hasData = true;
            final key = _devKeyOf(brand, sensorId);
            final old = _devs[key];
            if (old == null) {
              _devs[key] = _Dev(mmolL, trend, brand, ts);
            } else {
              old.v = mmolL;
              old.trend = trend;
              old.ts = ts;
              old.brand = brand;
            }
            _hist.add(_Pt(mmolL, ts, key));
            if (_hist.length > 500) {
              _hist = _hist.sublist(_hist.length - 500);
            }
          });
          _buzzForLevel();
        },
      );
    } catch (_) {
      _watchSubOn = false;
    }
  }

  /// 断链检查：监听开着但 5 分钟没数 → 震动 + 自动重扫一次。
  Future<void> _checkLink() async {
    if (!mounted || !_lowPowerOn) return;
    if (DateTime.now().difference(_lastDataAt).inMinutes < 5) return;
    if (_linkLostBuzzed) return; // 提醒过就不再震，等下一次有数复位
    _linkLostBuzzed = true;
    try {
      // 三长震：断链提醒（和低血糖三短震区分：间隔 700ms）
      for (var i = 0; i < 3; i++) {
        HapticFeedback.heavyImpact();
        await Future.delayed(const Duration(milliseconds: 700));
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _scanState = '断链重连中…');
    try {
      await _manager.disconnect();
      final err = await _manager.startScan();
      if (!mounted) return;
      setState(
          () => _scanState = err ?? _manager.state.toString().split('.').last);
      if (err == null) _lastDataAt = DateTime.now(); // 重连计时重来
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sportTimer?.cancel();
    _linkWatchdog?.cancel();
    _pager.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// 抬腕/回前台：血糖从库补最新（含历史），运动三件套刷一次——
  /// 手表表盘的"抬腕显示"本质就是 resumed 时立刻有数，不转菊花。
  /// 顺手把云下行订阅补上：配对码登录是进页面之后才发生的，
  /// initState 那次订阅多半因"没登录"被跳过，回来必须重试。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadLocal();
      _loadSport();
      _startWatchCloudSub();
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

  /// 先读本机库最新一条 + 最近历史（手表独立用：自己扫自己存，不依赖手机）。
  /// 历史按发射器归设备页：几个发射器启动就分几个数值页，3 个就 3 页。
  Future<void> _loadLocal() async {
    try {
      await AppDatabase.init();
      final rows = await AppDatabase.instance.recentReadings(limit: 1);
      final hist =
          await AppDatabase.instance.readingsLast24h(limit: 288);
      if (!mounted) return;
      final pts = <_Pt>[];
      final devLatest = <String, _Dev>{};
      for (final m in hist) {
        final v = (m['value_mmol_l'] as num?)?.toDouble();
        final t = DateTime.tryParse('${m['created_at'] ?? ''}');
        if (v != null && v > 0 && t != null) {
          final brand = '${m['brand'] ?? ''}';
          final sensor = '${m['sensor_id'] ?? ''}';
          final key = _devKeyOf(brand, sensor);
          pts.add(_Pt(v, t, key));
          final tr = (m['trend'] as num?)?.toInt() ?? 0;
          // 已用天数从库里seq回算（云下行的数seq也入库了，本机/云端一致）
          final seq = (m['min_from_start'] as num?)?.toInt();
          final days = _useDaysOf(_brandNameOf(brand), seq);
          final old = devLatest[key];
          if (old == null || t.isAfter(old.ts)) {
            devLatest[key] = _Dev(v, tr, brand, t, days);
          } else if (days != null) {
            old.useDays = days; // 同页更老的行也可能带更新的seq
          }
        }
      }
      setState(() {
        _hist = pts;
        _devs
          ..clear()
          ..addAll(devLatest);
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
      try {
        await CgmForegroundService.stop();
      } catch (_) {}
      if (mounted) setState(() => _lowPowerOn = false);
      return;
    }
    // 手表直连：和手机端一样的持续监听（continuous+lowLatency，无 timeout）。
    // 之前手表用 Timer 每分钟唤起扫 20 秒的省电轮询，在这块安卓手表上
    // burst 根本起不来（日志只有"省电监听"提示、从无"附近："设备），
    // 而昨天早上的手机端持续监听是可以的——先保证连上，费电以后再优化。
    //
    // 灭屏保活：手表和手机一样起 CgmForegroundService 前台服务，
    // 之前手表只裸 startScan()、切后台/灭屏 1-2 分钟就被系统杀掉丢数，
    // 起了服务后灭屏照样收，通知栏还能看到当前值。
    // 先要"忽略电池优化"，否则国产手表（ColorOS for Watch）灭屏就杀服务。
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {}
    final err = await _manager.startScan();
    if (err == null) {
      try {
        await CgmForegroundService.start();
      } catch (_) {}
    }
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

  // 手表锁定了谁：读 manager 白名单显示（空 = 自动模式），不用页面缓存——
  // 白名单是单例真相，页面只管显示 + 点选，点了立刻 setSelectedDevices。
  // 之前手机端吃过亏：页面缓存和 manager 两份值，显示以缓存为准就"选了显示未锁定"。
  bool _watchDevsOpen = false; // 默认折叠：圆屏小，只露一行

  /// 手表选设备区： nearby 有名的 + 当前白名单，二选一锁定。
  /// 小屏交互：默认折叠一行（"锁定：LT…/自动模式"），点展开多选，
  /// 打勾即生效（不用再找确认按钮）。
  Widget _buildWatchDevicePicker(double small) {
    final seen = _manager.seenDevices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    final locked = _manager.selectedNames;
    final summary = locked.isEmpty
        ? '自动模式（见谁连谁）'
        : '锁定：${locked.join('、')}';
    // 可选集合 = 附近有名的 + 已锁定的（已锁定但暂时扫不到也留着可取消）
    final names = <String>{};
    for (final s in seen) {
      names.add(s.name.toUpperCase());
    }
    names.addAll(locked);
    final list = names.toList()..sort();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () => setState(() => _watchDevsOpen = !_watchDevsOpen),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '手表连谁 · $summary ${_watchDevsOpen ? '▲' : '▼'}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: small, color: Colors.white70),
              ),
            ),
          ),
          if (_watchDevsOpen) ...[
            if (list.isEmpty)
              Text('附近暂无设备：先点"手表监听"扫一轮',
                  style: TextStyle(fontSize: small, color: Colors.grey)),
            for (final n in list.take(12))
              GestureDetector(
                onTap: () async {
                  // 点一下 = 只锁这一台；点已锁定的 = 取消回自动
                  final next =
                      locked.contains(n) ? <String>{} : {n};
                  await _manager.setSelectedDevices(next);
                  if (!mounted) return;
                  setState(() {}); // 白名单变了，summary/✅ 重刷
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(locked.contains(n) ? '✅ ' : '⭕ ',
                          style: TextStyle(fontSize: small)),
                      Flexible(
                        child: Text(n,
                            style: TextStyle(
                                fontSize: small,
                                color: locked.contains(n)
                                    ? Colors.green
                                    : Colors.white70)),
                      ),
                    ],
                  ),
                ),
              ),
            Text('点一下锁定，再点取消；云只同步血糖不同步选择',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: small - 1, color: Colors.grey)),
          ],
        ],
      ),
    );
  }

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
                // 按设备分页：几个发射器就几个数值页（2 个 2 页，3 个 3 页），
                // 后面再跟历史 + 统计。Tab 标签截断看不清的，页头有全名。
                child: PageView(
                  controller: _pager,
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    // 数值页：每个设备一页（没数时 1 页占位）
                    if (_devKeys.isEmpty)
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
                      )
                    else
                      for (final key in _devKeys)
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
                            child: _buildDeviceValuePage(
                              key,
                              statusColor: statusColor,
                            ),
                          ),
                        ),
                    // 历史（点一下切范围，长按开关监听）
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
                    // 统计（点一下切 7/14/30，长按开关监听）
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
              ), // Expanded(PageView 数值N页 + 历史 + 统计）结束
              const SizedBox(height: 4),
              // 页点：数值页（设备数）+ 历史 + 统计，当前页高亮
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  _pageCount,
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

  /// 单设备数值页：这个发射器自己的值/趋势/时间（几个设备就几个页，
  /// 左右滑切换对比；大字颜色按设备配色，不再只看红绿）。
  /// 没数时的占位页复用旧 _buildValuePage（监听按钮 + 诊断都在那）。
  Widget _buildDeviceValuePage(String key,
      {required Color statusColor}) {
    final d = _devs[key];
    if (d == null) return _buildValuePage(statusColor: statusColor);
    final devColor = _devColor(key);
    final low = d.v < _lowThreshold;
    final high = d.v > _highThreshold;
    final small = widget.shape.isCircular ? 11.0 : 13.0;
    final big = widget.shape.isCircular ? 30.0 : 38.0;
    final warn = low || high;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 设备名行：全名 + 配色点（哪个页一目了然）
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: devColor,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                key,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: small, color: Colors.white70),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (warn)
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: low ? Colors.blue : Colors.red,
              borderRadius: BorderRadius.circular(
                  widget.shape.isCircular ? 16 : 8),
            ),
            child: Text(
              low ? '⚠️ 低血糖' : '⚠️ 高血糖',
              style: TextStyle(
                color: Colors.white,
                fontSize: small + 2,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        if (warn) const SizedBox(height: 8),
        Text(
          d.v.toStringAsFixed(1),
          style: TextStyle(
            fontSize: big,
            fontWeight: FontWeight.bold,
            color: warn ? (low ? Colors.blue : Colors.red) : devColor,
          ),
        ),
        Text(
          '${(d.v * 18.0182).toStringAsFixed(0)} mg/dL ${_trendLabel(d.trend)}',
          style: TextStyle(fontSize: small, color: Colors.grey),
        ),
        const SizedBox(height: 2),
        Text(
          _fmtDateTime(DateTime.now()),
          style: TextStyle(fontSize: small + 2, color: Colors.white70),
        ),
        const SizedBox(height: 2),
        Text(
          '${d.brand} · ${_fmtTime(d.ts)}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: small, color: Colors.grey),
        ),
        // 已用天数（微泰分钟口径才有；硅基不显示，免得瞎报）。
        // 只提醒不锁死：到期停播是发射器自己停的，App 侧继续收。
        if (d.useDays != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              d.useDays! >= 14
                  ? '已用 ${d.useDays} 天（到期附近，数值勤对照指血）'
                  : '已用 ${d.useDays} 天',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: small,
                  color: d.useDays! >= 14 ? Colors.orange : Colors.grey),
            ),
          ),
        const SizedBox(height: 8),
        // 心率/步数卡片（和旧数值页一致，抬腕一眼全）
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
        const SizedBox(height: 12),
      ],
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
        // 手表选设备：附近有名的列出来点选锁定（和手机"只连选中的"同口径）。
        // 之前手表没有选设备入口：要么自动乱连（YD/耳机都连），要么手机锁了
        // LT、手表还在自动模式——这就是"手表不知道咋连硅基"的病根。
        // 数据源勾选不同步：云只同步血糖，不同步"选了谁"，两端各选各的。
        _buildWatchDevicePicker(small),
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

  /// 第 2 页：历史曲线 + 最近 8 条（点一下切 3/6/12/24h）。
  /// 多设备同图分色画：每个发射器一条线 + 图例（短名 + 配色点），
  /// 一眼看出两个仪器的差。对不上号是之前最大的槽点。
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
    // 图例：出现过的设备各一个配色点 + 短名（和数值页同色）
    final legendDevs =
        pts.map((p) => p.dev).where((d) => d.isNotEmpty).toSet().toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('近 $_rangeH 小时 · ${pts.length} 点',
            style: TextStyle(fontSize: small, color: Colors.grey)),
        if (legendDevs.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            children: legendDevs.map((d) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _devColor(d),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(_shortDev(d),
                      style: TextStyle(
                          fontSize: small - 1,
                          color: Colors.white70)),
                ],
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 4),
        SizedBox(
          height: widget.shape.isCircular ? 110 : 150,
          width: double.infinity,
          child: CustomPaint(
            painter: _SparkPainter(
              pts: pts,
              low: _lowThreshold,
              high: _highThreshold,
              colors: {
                for (final d in legendDevs) d: _devColor(d),
              },
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
        // 最近 8 条列表（时间 + 数值 + 归属短名，一行一条，对得上号）
        ...tail.reversed.map((p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.dev.isNotEmpty)
                        Container(
                          width: 6,
                          height: 6,
                          margin:
                              const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _devColor(p.dev),
                          ),
                        ),
                      Text(_fmtTime(p.t),
                          style: TextStyle(
                              fontSize: small,
                              color: Colors.grey)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (p.dev.isNotEmpty)
                        Text(_shortDev(p.dev),
                            style: TextStyle(
                                fontSize: small - 1,
                                color: Colors.white54)),
                      const SizedBox(width: 6),
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
  // 发射器归属（品牌 · 传感器，空=未知/老数据），多设备曲线分色用
  final String dev;
  _Pt(this.v, this.t, [this.dev = '']);
}

/// 单设备快照（数值页一页一个：值/趋势/品牌/时间 + 已用天数）
class _Dev {
  double v;
  int trend;
  String brand;
  DateTime ts;
  // 发射器已用天数（微泰分钟序号/60/24 取整；硅基 seq 非分钟口径时为 null
  // 不显示，免得瞎报。到期停播前心里有数，不锁死只提醒）。
  int? useDays;
  _Dev(this.v, this.trend, this.brand, this.ts, [this.useDays]);
}

/// 火花线：血糖曲线 + 3.9/10.0 阈值虚线。
/// 多设备分色：colors[dev] 给该发射器的线色，没给的走默认绿。
class _SparkPainter extends CustomPainter {
  final List<_Pt> pts;
  final double low;
  final double high;
  final Map<String, Color> colors;
  _SparkPainter(
      {required this.pts,
      required this.low,
      required this.high,
      this.colors = const {}});

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

    // 按发射器分组画线：各设备各一条，颜色和数值页/图例对上。
    // 组内单点画圆点（不够连线时不断线假象）。
    final order = <String>[];
    final byDev = <String, List<int>>{};
    for (var i = 0; i < pts.length; i++) {
      final d = pts[i].dev;
      if (!byDev.containsKey(d)) {
        byDev[d] = [];
        order.add(d);
      }
      byDev[d]!.add(i);
    }
    for (final d in order) {
      final idx = byDev[d]!;
      final c = colors[d] ?? Colors.green;
      final line = Paint()
        ..color = c
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      if (idx.length == 1) {
        canvas.drawCircle(
            Offset(x(idx.first), y(pts[idx.first].v)), 2.5, line..style = PaintingStyle.fill);
        continue;
      }
      final path = Path();
      for (var k = 0; k < idx.length; k++) {
        final p = Offset(x(idx[k]), y(pts[idx[k]].v));
        if (k == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, line);
    }
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
