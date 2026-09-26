import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';

/// 后台收数前台服务入口（独立 isolate，App 退后台/锁屏也跑）
@pragma('vm:entry-point')
void cgmBackgroundEntryPoint() {
  FlutterForegroundTask.setTaskHandler(CgmBackgroundHandler());
}

class CgmBackgroundHandler extends TaskHandler {
  StreamSubscription? _sub;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await AppDatabase.init();
    // 注意：后台 isolate 里不做 BLE 扫描，只保活 + 刷新通知。
    // 之前后台 isolate 里起 startLowPowerWatch，但 flutter_blue_plus 的
    // MethodChannel 在后台 isolate 没注册，startScan 静默抛异常（被 catch吞掉），
    // 后台根本扫不到；同时前台 startScan 见 backgroundRunning=true 就跳过平台扫描、
    // 只挂监听——结果切后台后两边都没在扫，这就是"一切后台就断"的病根。
    // 修法：扫描永远归主 isolate（前台页点的开始监听），后台服务只负责
    // 拿 wake lock + 常驻通知把进程保住，主 isolate 的扫描在后台继续跑。
    // 后台与主 isolate 的 readingStream 不互通，之前靠 sendDataToMain 补，
    // 现在后台不收数，主 isolate 直接入库+UI，不需要这条桥（BgSync 保留给兼容）。
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
        autoRunOnBoot: true, // 开机自启：重启后后台监听自己回来
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
    // 告诉前台 manager：后台正在扫，前台只挂监听别碰平台扫描
    // （否则前台 startScan 会把后台的扫描停掉 → 切后台就断）
    BleCgmManager.backgroundRunning = true;
  }

  static Future<void> stop() async {
    if (!_started) return;
    await FlutterForegroundTask.stopService();
    _started = false;
    BleCgmManager.backgroundRunning = false;
  }
}
