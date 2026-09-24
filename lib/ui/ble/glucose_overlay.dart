import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import '../../data/datasource/local_db.dart';

import '../../services/bg_sync.dart';

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

  /// 权限：overlay 弹窗失败，九成是国产 ROM（ColorOS/OriginOS/MagicOS）
  /// 在系统侧关了“悬浮窗/显示在其他应用上层”开关——插件的
  /// requestPermission 只跳应用详情页，用户得在里面手动开，开完退到
  /// 桌面才会飘窗，所以拿不到权限就直接报去哪开，不重试。
  static Future<bool> ensurePermission() async {
    final ok = await FlutterOverlayWindow.isPermissionGranted();
    if (ok == true) return true;
    // 注意：插件调起的是 actionManageOverlayPermission 系统页，
    // 用户可能只是看了眼就按返回——requestPermission 的返回值不可信，
    // 用 requestPermission() 只负责"跳过去"，回来后以二次查询为准。
    try {
      await FlutterOverlayWindow.requestPermission();
    } catch (_) {}
    // 给系统页一点关闭时间，再二次确认（ColorOS 跳的是详情页，
    // 用户需手动开悬浮窗开关——不开这里就是 false，直说去哪开）
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      return await FlutterOverlayWindow.isPermissionGranted() == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> show() async {
    if (_showing) return;
    try {
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: '血糖悬浮窗',
        overlayContent: '实时血糖显示中',
        // clickThrough 会让窗不响应触摸但在部分 ROM 上整窗不渲染；
        // 默认 flag（可点击+可聚焦）最稳，窗出来后手指可拖走。
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.right,
        alignment: OverlayAlignment.centerRight,
        width: 160,
        height: 72,
      );
      _showing = true;
    } catch (_) {
      _showing = false;
      rethrow;
    }
  }

  /// 系统侧真实状态（_showing 只是本 App 的标记，系统可能没显示——
  /// 比如 ColorOS 悬浮窗权限没开时 show() 不报错但就是不出窗。
  /// 以这个为准告诉用户真相）
  static Future<bool> isActive() async {
    try {
      return await FlutterOverlayWindow.isActive();
    } catch (_) {
      return false;
    }
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
