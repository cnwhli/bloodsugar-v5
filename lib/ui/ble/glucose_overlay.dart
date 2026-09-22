import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../../data/datasource/local_db.dart';

/// 悬浮窗血糖入口（独立 isolate，Android SYSTEM_ALERT_WINDOW）
/// 注意：入口函数名必须是 overlayMain（插件原生侧写死查找该符号）
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GlucoseOverlayWidget(),
  ));
}

/// 悬浮窗小组件：当前值 + 趋势 + 更新时间，可拖动
class GlucoseOverlayWidget extends StatefulWidget {
  const GlucoseOverlayWidget({super.key});

  @override
  State<GlucoseOverlayWidget> createState() => _GlucoseOverlayWidgetState();
}

class _GlucoseOverlayWidgetState extends State<GlucoseOverlayWidget> {
  double _v = 0;
  String _trend = '';
  String _time = '';
  Color _c = Colors.green;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    // 主 App 每次收到读数都会 shareData '{"v":x,"trend":n,"t":"HH:MM:SS"}'
    _sub = FlutterOverlayWindow.overlayListener.listen((event) {
      if (event is String && event.contains('v')) _applyFromApp(event);
    });
    _loadLatest();
  }

  Future<void> _loadLatest() async {
    try {
      await AppDatabase.init();
      final rows = await AppDatabase.instance.recentReadings(limit: 1);
      if (rows.isNotEmpty && mounted) {
        setState(() => _applyMap(
              (rows.first['value_mmol_l'] as num?)?.toDouble() ?? 0,
              (rows.first['trend'] as num?)?.toInt() ?? 0,
              _fmtTime('${rows.first['created_at'] ?? ''}'),
            ));
      }
    } catch (_) {}
  }

  void _applyFromApp(String json) {
    try {
      final v = double.tryParse(
              RegExp(r'"v":([\d.]+)').firstMatch(json)?.group(1) ?? '') ??
          0;
      final trend = int.tryParse(
              RegExp(r'"trend":(\d+)').firstMatch(json)?.group(1) ?? '') ??
          0;
      final t = RegExp(r'"t":"([^"]+)"').firstMatch(json)?.group(1) ?? '';
      if (mounted && v > 0) setState(() => _applyMap(v, trend, t));
    } catch (_) {}
  }

  void _applyMap(double v, int trend, String t) {
    _v = v;
    _trend = _trendLabel(trend);
    _time = t;
    _c = v < 3.9 ? Colors.blue : (v > 10.0 ? Colors.red : Colors.green);
  }

  String _trendLabel(int t) {
    switch (t) {
      case 0:
        return '→';
      case 1:
        return '↗';
      case 2:
        return '↑';
      case 3:
        return '↘';
      case 4:
        return '↓';
      default:
        return '';
    }
  }

  String _fmtTime(String s) {
    try {
      final ts = DateTime.parse(s);
      return '${ts.hour.toString().padLeft(2, '0')}:'
          '${ts.minute.toString().padLeft(2, '0')}:'
          '${ts.second.toString().padLeft(2, '0')}';
    } catch (_) {
      return s.length >= 19 ? s.substring(11, 19) : s;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _c, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _v > 0 ? _v.toStringAsFixed(1) : '--',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _c == Colors.green ? Colors.white : _c,
              ),
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_trend,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.white70)),
                Text(_time,
                    style:
                        const TextStyle(fontSize: 10, color: Colors.white54)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 悬浮窗开关封装（蓝牙页 / 首页调用）
class GlucoseOverlay {
  static bool _showing = false;
  static bool get isShowing => _showing;

  static Future<bool> ensurePermission() async {
    final ok = await FlutterOverlayWindow.isPermissionGranted();
    if (ok == true) return true;
    final granted = await FlutterOverlayWindow.requestPermission();
    return granted == true;
  }

  static Future<void> show() async {
    if (_showing) return;
    await FlutterOverlayWindow.showOverlay(
      enableDrag: true,
      overlayTitle: '血糖悬浮窗',
      overlayContent: '实时血糖显示中',
      flag: OverlayFlag.defaultFlag,
      visibility: NotificationVisibility.visibilityPublic,
      positionGravity: PositionGravity.right,
      alignment: OverlayAlignment.centerRight,
      width: 160,
      height: 72,
    );
    _showing = true;
  }

  static Future<void> hide() async {
    if (!_showing) return;
    await FlutterOverlayWindow.closeOverlay();
    _showing = false;
  }

  /// 主 App 收到新读数 → 推送到悬浮窗
  static Future<void> push(double v, int trend, String time) async {
    if (!_showing) return;
    try {
      await FlutterOverlayWindow.shareData(
          '{"v":$v,"trend":$trend,"t":"$time"}');
    } catch (_) {}
  }
}
