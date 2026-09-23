import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/alert_service.dart';
import '../../services/bg_sync.dart';
import '../../services/health_bridge.dart';
import 'cgm_foreground_service.dart';
import 'glucose_overlay.dart';

/// BLE 扫描 + 连接页面（多品牌 CGM）
///
/// 流程：
/// 1. 点"扫描" → 按各品牌 service UUID 过滤广播
/// 2. 微泰二代（AiDEX）：被动广播，靠近即自动读数，无需点连接
/// 3. 其他品牌：发现后自动连接 + 握手 + 订阅，读数存库 + 首页显示
class BleScannerScreen extends StatefulWidget {
  const BleScannerScreen({super.key});

  @override
  State<BleScannerScreen> createState() => _BleScannerScreenState();
}

class _BleScannerScreenState extends State<BleScannerScreen> {
  final _manager = BleCgmManager();
  List<GlucoseReading> _readings = [];
  String _statusText = '就绪';
  List<String> _log = [];
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    AppDatabase.init();
    // manager 是单例常驻：先铺内存缓存，再从数据库补（App 重启也不丢）
    _readings = List.of(_manager.history);
    _reloadFromDb();
    _statusText = _manager.state.toString().split('.').last;
    _subs.add(_manager.stateStream.listen((state) {
      if (!mounted) return;
      setState(() => _statusText = state.toString().split('.').last);
    }));
    // 后台收数通知：退后台期间的数进来，蓝牙页列表自动补上（不用退出重进）
    _subs.add(BgSync.stream.listen((msg) {
      if (!mounted) return;
      _applyBgReading(msg);
    }));
    // App 从后台切回前台：若之前在扫、系统却停了扫，自动续扫并提示
    _subs.add(_lifecycleSub());
    _subs.add(_manager.logStream.listen((msg) {
      if (!mounted) return;
      setState(() {
        _log.add(msg);
        if (_log.length > 50) _log.removeAt(0);
      });
    }));
    _subs.add(_manager.readingStream.listen((reading) async {
      if (!mounted) return;
      setState(() {
        _readings.insert(0, reading);
        if (_readings.length > 100) _readings.removeLast();
      });
      await AppDatabase.instance.insertReading(reading);
      // 系统健康平台同步（OPPO Watch X 官方血糖表盘只能从这里读数）
      HealthBridge.writeGlucose(reading.valueMmolL, reading.timestamp);
      // 悬浮窗同步最新值（含时间）
      GlucoseOverlay.push(reading.valueMmolL, reading.trend,
          _fmtTime(reading.timestamp));
      // 超阈值报警（震动/声音/震动+声音，由设置页决定）
      if (mounted) {
        final msg = await AlertService().check(reading.valueMmolL);
        if (msg != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 5),
              backgroundColor: Colors.red[700],
              action: SnackBarAction(
                label: '设置',
                textColor: Colors.white,
                onPressed: () =>
                    Navigator.pushNamed(context, '/alert-settings'),
              ),
            ),
          );
        }
      }
    })); // readingStream.listen 结束
  }

  @override
  void dispose() {
    // 只取消页面自己的订阅，不关 manager：监听在后台继续跑，
    // 切回来从 manager.history 恢复显示。App 退出才停（见 disconnect 按钮）。
    WidgetsBinding.instance.removeObserver(_lifecycleObs);
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  // ---- 后台收数通知：把后台期间收的数补进列表（不用退出重进）----
  final _lifecycleObs = _ScanLifecycleObserver();
  StreamSubscription<String> _lifecycleSub() {
    _lifecycleObs.onResumed = () async {
      if (!mounted) return;
      // 切回前台：先把后台期间入库的数从库里补上
      await _reloadFromDb();
      if (!mounted) return;
      // 若之前在扫但系统停了扫（国产 ROM 常见），自动续扫
      if (_manager.foregroundScanActive &&
          _manager.state != BleCgmState.scanning) {
        _manager.startScan(quiet: true);
        _log.add('已从后台返回，监听自动续上');
        if (_log.length > 50) _log.removeAt(0);
        setState(() {});
      }
    };
    WidgetsBinding.instance.addObserver(_lifecycleObs);
    // 返回一个永不结束的订阅占位（随 _subs 一起 cancel，无实际事件）
    return Stream<String>.empty().listen((_) {});
  }

  /// 后台 isolate 发来的 "value|trend|isoTime"：入库（去重）+ 列表置顶
  Future<void> _applyBgReading(String msg) async {
    try {
      final parts = msg.split('|');
      if (parts.length < 3) return;
      final v = double.tryParse(parts[0]) ?? 0;
      if (v <= 0) return;
      final trend = int.tryParse(parts[1]) ?? 0;
      final ts = DateTime.tryParse(parts[2]) ?? DateTime.now();
      final r = GlucoseReading(
        valueMgDl: v * 18.0182,
        timestamp: ts,
        trend: trend,
        brand: _manager.protocols.first.brand,
      );
      await AppDatabase.instance.insertReading(r);
      if (!mounted) return;
      setState(() {
        _readings.insert(0, r);
        if (_readings.length > 100) _readings.removeLast();
      });
      GlucoseOverlay.push(v, trend, _fmtTime(ts));
    } catch (_) {}
  }

  /// 从数据库补历史（新读数入库后也会调用，保持内存与数据库一致）
  Future<void> _reloadFromDb() async {
    try {
      await AppDatabase.init();
      final rows =
          await AppDatabase.instance.recentReadings(limit: 100);
      if (!mounted) return;
      final fromDb = rows.map(GlucoseReading.fromDb).toList();
      // 合并：内存里有但库里没有的（刚收还没写完）保留，去重按时间戳+数值
      final keys = fromDb
          .map((r) =>
              '${r.timestamp.toString().substring(0, 19)}|${r.valueMmolL.toStringAsFixed(1)}')
          .toSet();
      final merged = List.of(fromDb);
      for (final r in _readings) {
        final k =
            '${r.timestamp.toString().substring(0, 19)}|${r.valueMmolL.toStringAsFixed(1)}';
        if (!keys.contains(k)) merged.add(r);
      }
      merged.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      setState(() {
        _readings =
            merged.length > 100 ? merged.sublist(0, 100) : merged;
      });
    } catch (_) {}
  }

  /// 时间格式：今天显示 HH:MM:SS，跨天显示 MM-DD HH:MM
  String _fmtTime(DateTime ts) {
    final now = DateTime.now();
    final hh = ts.hour.toString().padLeft(2, '0');
    final mm = ts.minute.toString().padLeft(2, '0');
    final ss = ts.second.toString().padLeft(2, '0');
    if (ts.year == now.year && ts.month == now.month && ts.day == now.day) {
      return '$hh:$mm:$ss';
    }
    return '${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接血糖仪'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Center(
              child: Text(
                _statusText,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 状态栏
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[200],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('状态: $_statusText',
                    style: const TextStyle(fontSize: 14)),
                Text('已读: ${_readings.length} 条',
                    style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
          // 支持品牌提示
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.blue[50],
            child: const Text(
              '支持：微泰 AiDEX（广播自动读）· Libre 2/3 · Dexcom G6/G7 · 硅基 GS1/GS3 · Accu-Chek',
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
          // 操作按钮：扫描=前台持续监听+后台前台服务（退后台/锁屏继续收）
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          // 先要"忽略电池优化"，否则国产 ROM 锁屏就杀扫描——
                          // 放后台断数的另一个常见病根
                          await FlutterForegroundTask
                              .requestIgnoreBatteryOptimization();
                          await _manager.startScan();
                          await CgmForegroundService.start();
                        },
                        icon: const Icon(Icons.bluetooth_searching),
                        label: const Text('扫描'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          await CgmForegroundService.stop();
                          await _manager.disconnect();
                        },
                        icon: const Icon(Icons.bluetooth_disabled),
                        label: const Text('断开'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 悬浮窗开关：切到别的 App 也能看到血糖（含时间）
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      if (GlucoseOverlay.isShowing) {
                        await GlucoseOverlay.hide();
                        setState(() {});
                      } else {
                        final ok =
                            await GlucoseOverlay.ensurePermission();
                        if (!mounted) return;
                        if (!ok) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    '请在系统设置中允许"显示在其他应用上层"')),
                          );
                          return;
                        }
                        await GlucoseOverlay.show();
                        // 打开即推一条当前值，避免空窗
                        if (_readings.isNotEmpty && mounted) {
                          GlucoseOverlay.push(
                              _readings.first.valueMmolL,
                              _readings.first.trend,
                              _fmtTime(
                                  _readings.first.timestamp));
                        }
                        setState(() {});
                      }
                    },
                    icon: const Icon(Icons.picture_in_picture_alt),
                    label: Text(GlucoseOverlay.isShowing
                        ? '关闭悬浮窗'
                        : '开启悬浮窗（退到桌面也显示）'),
                  ),
                ),
              ],
            ),
          ),
          // 最近读数
          Expanded(
            child: _readings.isEmpty
                ? const Center(
                    child: Text(
                      '暂无数据\n\n微泰二代：点"扫描"，发射器靠近手机即自动出数\n其他品牌：扫描发现后自动连接',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount:
                        _readings.length > 20 ? 20 : _readings.length,
                    itemBuilder: (context, i) {
                      final r = _readings[i];
                      return ListTile(
                        title: Text(
                          '${r.valueMmolL.toStringAsFixed(1)} mmol/L',
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          // 时间精确到秒 + 日期（跨天也能看出来）
                          '${r.brandLabel} · ${_fmtTime(r.timestamp)}',
                        ),
                        trailing: Icon(
                          r.status == 'low'
                              ? Icons.arrow_downward
                              : r.status == 'high'
                                  ? Icons.arrow_upward
                                  : Icons.check_circle,
                          color: r.status == 'low'
                              ? Colors.blue
                              : r.status == 'high'
                                  ? Colors.red
                                  : Colors.green,
                        ),
                      );
                    },
                  ),
          ),
          // 日志（底部）
          Container(
            height: 80,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
            child: ListView(
              children: _log
                  .sublist(_log.length > 10 ? _log.length - 10 : 0)
                  .map((l) => Text(l, style: const TextStyle(fontSize: 11)))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// App 前后台切换监听：切回前台时把后台期间的数补上 + 断了自动续扫
class _ScanLifecycleObserver with WidgetsBindingObserver {
  VoidCallback? onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed?.call();
  }
}
