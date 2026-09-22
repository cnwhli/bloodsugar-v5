import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/alert_service.dart';

/// 后台收数前台服务入口（独立 isolate，App 退后台/锁屏也跑）
@pragma('vm:entry-point')
void cgmBackgroundEntryPoint() {
  FlutterForegroundTask.setTaskHandler(CgmBackgroundHandler());
}

class CgmBackgroundHandler extends TaskHandler {
  BleCgmManager? _m;
  StreamSubscription? _sub;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _m = BleCgmManager();
    await AppDatabase.init();
    // 后台只做一件事：收数 → 入库。UI 由各页订阅 readingStream 自己刷。
    _sub = _m!.readingStream.listen((r) async {
      try {
        await AppDatabase.instance.insertReading(r);
        await AlertService().check(r.valueMmolL);
      } catch (_) {}
    });
    // 后台用省电模式：扫 15 秒、停 45 秒（发射器 1 分钟广播一次，不漏数）
    await _m!.startLowPowerWatch();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // 常驻通知栏刷新：最新值（轻量查库一条）
    AppDatabase.instance.recentReadings(limit: 1).then((rows) {
      if (rows.isNotEmpty) {
        final v =
            (rows.first['value_mmol_l'] as num?)?.toDouble() ?? 0;
        FlutterForegroundTask.updateService(
          notificationText: '当前血糖 ${v.toStringAsFixed(1)} mmol/L',
        );
      }
    }).catchError((_) {});
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _sub?.cancel();
  }
}

/// 前台服务启停封装（蓝牙页"扫描/断开"按钮调用）
class CgmForegroundService {
  static bool _started = false;
  static bool get isRunning => _started;

  static Future<void> start() async {
    if (_started) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cgm_bg',
        channelName: '血糖后台监听',
        channelDescription: '锁屏/后台持续接收发射器广播',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions:
          const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: false,
        allowWakeLock: true, // 后台扫蓝牙必须持部分唤醒锁，否则 CPU 睡死收不到广播
        allowWifiLock: false,
      ),
    );
    await FlutterForegroundTask.startService(
      notificationTitle: '血糖管家监听中',
      notificationText: '等待发射器广播…',
      callback: cgmBackgroundEntryPoint,
      // Android 14+ 必须声明前台服务类型 connectedDevice，否则 startForeground 被拒、服务秒死
      serviceTypes: [ForegroundServiceTypes.connectedDevice],
    );
    _started = true;
  }

  static Future<void> stop() async {
    if (!_started) return;
    await FlutterForegroundTask.stopService();
    _started = false;
  }
}
