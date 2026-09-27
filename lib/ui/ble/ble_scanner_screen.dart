import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/alert_service.dart';
import '../../services/bg_sync.dart';
import '../../services/cloud_sync.dart';
import '../../services/glucodata_forward.dart';
import '../../services/nightscout_sync.dart';
import '../../services/health_bridge.dart';
import '../../services/phone_widget.dart';
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
  // 手动选设备：扫到的可连设备多选 + 白名单开关（默认自动模式见谁连谁）
  Set<String> _picked = {}; // 页面勾选（大写名）；点"只连选中的"才生效
  Map<String, SeenDevice> _seen = {};
  bool _manualOn = false; // 仅 initState 回读用；显示一律以 manager 白名单为准
  // 分钟级断流盯防：页面开着时每 30 秒查一次 manager，没新数就打日志、
  // 3 分钟报断链。之前 checkLinkLost/checkDataGap 写了但没人调——
  // 这就是"23:32→23:25 七分钟空洞"全程静默无感知的病根。
  Timer? _gapTimer;

  @override
  void initState() {
    super.initState();
    AppDatabase.init();
    // 历史补洞回调：广播包里带的前 1/2 分钟点入库后，列表自动补上
    _manager.onBackfilled = (_) {
      if (mounted) _reloadFromDb();
    };
    // 页面开着就盯着：30 秒查一次，空洞 90 秒被看见、3 分钟报断链
    _gapTimer =
        Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      _manager.checkDataGap(); // 日志在 logStream 里，页面自动显示
      if (_manager.checkLinkLost()) {
        _log.add('断链提醒：3 分钟没新数了，自动重扫一次…');
        if (_log.length > 50) _log.removeAt(0);
        _manager.startScan(quiet: true);
      }
    });
    // manager 是单例常驻：先铺内存缓存，再从数据库补（App 重启也不丢）
    _readings = List.of(_manager.history);
    _reloadFromDb();
    // 手动选设备：读回上次白名单 + 订阅可选设备更新
    _manager.loadSelectedDevices().then((_) {
      if (!mounted) return;
      setState(() {
        _manualOn = _manager.isManualSelect;
        _picked = Set.of(_manager.selectedNames);
        _seen = Map.of(_manager.seenDevices);
      });
    });
    _subs.add(_manager.seenDevicesStream.listen((_) {
      if (!mounted) return;
      setState(() => _seen = Map.of(_manager.seenDevices));
    }));
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
      // 库去重：前台和后台 isolate 会同时收到同一条广播先后入库，
      // 按发射器分钟序号判重（同一广播必然同序号）。UI 列表同理：
      // 有序号比序号，无序号才按 45 秒同值比——旧逻辑按同值比会把
      // 下一分钟同值的新点当重复吞掉，看起来像数值冻结。
      final inserted =
          await AppDatabase.instance.insertReadingDedup(reading);
      if (!mounted) return;
      setState(() {
        final dup = reading.minFromStart != null
            ? _readings.any(
                (r) => r.minFromStart == reading.minFromStart)
            : _readings.any((r) =>
                (r.valueMmolL - reading.valueMmolL).abs() < 0.06 &&
                r.timestamp.difference(reading.timestamp).inSeconds.abs() <
                    45);
        if (!dup) {
          _readings.insert(0, reading);
          if (_readings.length > 100) _readings.removeLast();
        }
      });
      if (!inserted) return; // 重复广播：UI 已有，后续推送/报警跳过
      // 系统健康平台同步（OPPO Watch X 官方血糖表盘只能从这里读数）
      HealthBridge.writeGlucose(reading.valueMmolL, reading.timestamp);
      // 云同步上传（登录后自动传，双方秒级互通；没登录/断网静默跳过）。
      // localId 用库自增 id：刚入库，查同（序号,发射器）/时间值拿回 id。
      CloudSync.pushReading(
        localId: await AppDatabase.instance.latestReadingId(reading),
        mmolL: reading.valueMmolL,
        trend: reading.trend,
        brand: reading.brand.displayName,
        source: 'ble',
        seq: reading.minFromStart,
        sensorId: reading.sensorId,
        measuredAt: reading.timestamp,
      );
      // Nightscout 上传（配了自家 NS 服务器才传，家属远程看用）
      NightscoutSync.push(
        mgDl: reading.valueMgDl,
        time: reading.timestamp,
      );
      // GlucoData 标准广播转发（第三方表盘/车机/Tasker 可订阅读数）
      GlucoDataForward.push(
        mmolL: reading.valueMmolL,
        rateMgDlMin: 0,
        time: reading.timestamp,
        sensorId: reading.sensorId,
      );
      // 悬浮窗同步最新值（含时间）
      GlucoseOverlay.push(reading.valueMmolL, reading.trend,
          _fmtTime(reading.timestamp));
      // 桌面小组件同步推（蓝牙页收到第一手数，首页还没刷也先上桌面）
      PhoneWidget.push(
        mmolL: reading.valueMmolL,
        trendLabel: _trendArrow(reading.trend),
        time: _fmtTime(reading.timestamp),
      );
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
    _gapTimer?.cancel(); // 盯防计时器随页面走（manager 常驻，计时器不能留野的）
    _gapTimer = null;
    _manager.onBackfilled = null; // 补洞回调随页面解绑（manager 常驻，回调不能留野指针）
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

  /// 后台 isolate 发来的 v2 消息（BgSync.decode）：去重入库 + 列表置顶。
  /// 有序号按序号判（与 readingStream 同口径），无序号才按 120 秒同值比——
  /// 之前无序号，同一分钟的前后台双写全进列表，就是截图"6.3×4条同秒"。
  Future<void> _applyBgReading(String msg) async {
    try {
      final d = BgSync.decode(msg);
      if (d == null) return;
      final r = GlucoseReading(
        valueMgDl: d.v * 18.0182,
        timestamp: d.ts,
        trend: d.trend,
        brand: _manager.protocols.first.brand,
        minFromStart: d.seq,
        sensorId: d.sensorId,
      );
      final inserted =
          await AppDatabase.instance.insertReadingDedup(r);
      if (!mounted) return;
      // 不管库判重结果如何，只要列表里没有这条就置顶：
      // 后台 isolate 自己已写库，这边判重失败多半是自己刚写过，
      // 列表置顶不能省——否则"收了数但列表不显示"。
      setState(() {
        final dup = r.minFromStart != null
            ? _readings.any((e) =>
                e.minFromStart == r.minFromStart && e.sensorId == r.sensorId)
            : _readings.any((e) =>
                (e.valueMmolL - r.valueMmolL).abs() < 0.06 &&
                e.timestamp.difference(r.timestamp).inSeconds.abs() < 120);
        if (!dup) {
          _readings.insert(0, r);
          if (_readings.length > 100) _readings.removeLast();
        }
      });
      if (!inserted) return;
      GlucoseOverlay.push(d.v, d.trend, _fmtTime(d.ts));
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

  /// 趋势箭头（桌面小组件用：小组件面积极小，只放箭头不放文字）
  String _trendArrow(int trend) {
    switch (trend) {
      case 1:
        return '↗';
      case 2:
        return '↗↗';
      case 3:
        return '↘';
      case 4:
        return '↘↘';
      default:
        return '→';
    }
  }

  // ---- 手动选设备区： nearby 可连设备多选 + 锁定开关 ----
  // 默认折叠：只露一行"附近设备（N）+ 展开/锁定"，不占地方；
  // 之前一上来全展开，几十个蓝牙把血糖列表挤没。
  bool _pickerOpen = false;

  Widget _buildDevicePicker() {
    final names = _seen.keys.toList()..sort();
    // 显示以 manager 白名单为准：之前用本地 _manualOn，set 后不同步就
    // 显示"未锁定"，看着像没生效——"选了还是未锁定"的病根之一。
    final locked = _manager.selectedNames;
    final isLocked = locked.isNotEmpty;
    final summary = isLocked
        ? '锁定：${locked.join('、')}'
        : (_seen.isEmpty ? '扫描中…' : '附近 ${_seen.length} 台，未锁定（自动模式）');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey[700]!),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _pickerOpen = !_pickerOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('附近设备 · $summary',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70)),
                  ),
                  Text(_pickerOpen ? '收起' : '展开',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.lightBlue)),
                ],
              ),
            ),
          ),
          if (!_pickerOpen) const SizedBox.shrink(),
          if (_pickerOpen)
            Row(
              children: [
                const Text('勾选后点锁定，只连选中的',
                    style:
                        TextStyle(fontSize: 12, color: Colors.white70)),
                const Spacer(),
                TextButton(
                  // 点了就写白名单：以 manager 返回为准刷新本地状态，
                  // 不再"点了显示未锁定"。全取消 = 回自动模式。
                  onPressed: (_picked.isEmpty && !isLocked)
                      ? null
                      : () async {
                          if (isLocked && _picked.isEmpty) {
                            // 已锁定但全取消 = 回自动
                            await _manager.setSelectedDevices({});
                          } else {
                            await _manager.setSelectedDevices(_picked);
                          }
                          if (!mounted) return;
                          setState(() {
                            _manualOn = _manager.isManualSelect;
                            _picked = Set.of(_manager.selectedNames);
                            _seen = Map.of(_manager.seenDevices);
                          });
                        },
                  child: Text(isLocked
                      ? '已锁定（点我改选/全取消回自动）'
                      : '只连选中的'),
                ),
              ],
            ),
          if (_pickerOpen && isLocked)
            Text('锁定中：${locked.join('、')}',
                style: const TextStyle(fontSize: 12, color: Colors.green)),
          // 限高独立滚动：附近蓝牙多时多选区自己滚，不把血糖列表挤没——
          // "下面的内容都显示不了"的另一半病根（manager 侧已限 30 个）
          if (_pickerOpen)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Column(
                  children: names.map((k) {
                    final d = _seen[k]!;
                    final checked = _picked.contains(k);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text('${d.name}（${d.rssi}dBm）',
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text('${d.brandLabel} · ${d.mac}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white54)),
                      value: checked,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _picked.add(k);
                          } else {
                            _picked.remove(k);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- 血糖列表按设备分组：同一发射器一节，各看各的 ----
  Widget _buildGroupedList() {
    // 分组 key：sensorId 有就用（微泰后6位/AAC…），没有按品牌分
    final groups = <String, List<GlucoseReading>>{};
    for (final r in _readings) {
      final key = r.sensorId.isNotEmpty
          ? '${r.brandLabel} · ${r.sensorId}'
          : r.brandLabel;
      groups.putIfAbsent(key, () => []).add(r);
    }
    final keys = groups.keys.toList();
    return ListView.builder(
      itemCount: keys.length > 4 ? 4 : keys.length, // 最多4节，防刷屏
      itemBuilder: (context, gi) {
        final key = keys[gi];
        final items = groups[key]!;
        final shown = items.length > 10 ? items.sublist(0, 10) : items;
        return ExpansionTile(
          initiallyExpanded: gi == 0, // 第一节默认展开
          title: Text(
            '$key（最新 ${shown.first.valueMmolL.toStringAsFixed(1)} · ${_fmtTime(shown.first.timestamp)}）',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.bold),
          ),
          children: shown.map((r) {
            return ListTile(
              dense: true,
              title: Text(
                '${r.valueMmolL.toStringAsFixed(1)} mmol/L',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold),
              ),
              subtitle: Text(_fmtTime(r.timestamp)),
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
          }).toList(),
        );
      },
    );
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
          // 状态栏：深色模式下强制深底白字（之前白底在深色模式看不见字）
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[850],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('状态: $_statusText',
                    style: const TextStyle(
                        fontSize: 14, color: Colors.white)),
                Text('已读: ${_readings.length} 条',
                    style: const TextStyle(
                        fontSize: 14, color: Colors.white)),
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
                                    '请在系统设置 → 应用 → 血糖管家中允许"显示在其他应用上层"，开了后退到桌面才会飘出黑底小窗')),
                          );
                          return;
                        }
                        try {
                          await GlucoseOverlay.show();
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('悬浮窗打开失败：$e')),
                          );
                          return;
                        }
                        // 打开后核对系统侧是不是真出来了（ColorOS 常出现
                        // 权限显示开了但窗没出来的情况），没出来就直说
                        await Future.delayed(
                            const Duration(milliseconds: 800));
                        final active =
                            await GlucoseOverlay.isActive();
                        if (!mounted) return;
                        if (!active) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                  '系统没把悬浮窗显示出来：请到设置 → 应用 → 血糖管家 → 悬浮窗/显示在其他应用上层，手动打开后再点一次'),
                              duration: Duration(seconds: 6),
                            ),
                          );
                        }
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
          // 手动选设备区：扫到的可连设备多选，"只连选中的"锁定
          _buildDevicePicker(),
          // 最近读数（按设备分组：微泰/硅基各看各的，不再混一条线）
          Expanded(
            child: _readings.isEmpty
                ? const Center(
                    child: Text(
                      '暂无数据\n\n微泰二代：点"扫描"，发射器靠近手机即自动出数\n其他品牌：扫描发现后自动连接',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : _buildGroupedList(),
          ),
          // 日志（底部）：深色模式强制深底浅字（之前白底在深色模式看不见）
          Container(
            height: 80,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              border: Border(top: BorderSide(color: Colors.grey[700]!)),
            ),
            child: ListView(
              children: _log
                  .sublist(_log.length > 10 ? _log.length - 10 : 0)
                  .map((l) => Text(l,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white70)))
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
