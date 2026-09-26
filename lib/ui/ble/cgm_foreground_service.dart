import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../../data/datasource/local_db.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../services/alert_service.dart';
import '../../services/bg_sync.dart';
import '../../services/health_bridge.dart';

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
    // 注意：这里不要 ensureAuth/弹授权框。后台 isolate 直接 requestAuthorization
    // 会抛 MissingPluginException（health 插件的 MethodChannel 在后台 engine 没注册），
    // onStart 直接崩 → 服务秒死 → \"手表灭屏就断\"。
    // HealthBridge.writeGlucose 内部已 try-catch，失败只跳过写平台，不影响入库。
    // 前台 isolate（手表页/蓝牙页）该授的权都授过，后台只管收数入库。
    // 后台只做三件事：收数 → 入库 + 同步写系统健康平台（供手表官方表盘读）
    // + 通知主 isolate 刷新 UI（后台与主 isolate 的 readingStream 不互通，
    // 不 sendDataToMain 主 isolate 永远不知道有新数——"退后台就断"的病根之二）。
    _sub = _m!.readingStream.listen((r) async {
      try {
        await AppDatabase.instance.insertReadingDedup(r);
        await HealthBridge.writeGlucose(r.valueMmolL, r.timestamp);
        await AlertService().check(r.valueMmolL);
        // BgSync 发 mmol/L（主 isolate 按时间戳+数值去重，与序号无关）。
        // 后台 isolate 的 reading 带 minFromStart，入库走序号去重；
        // 主 isolate 收到后走 45 秒同值去重——两个窗口不打架。
        // v3：seq+sensorId 一起透过来（BgSync.encode），主 isolate 重建
        // reading 时带上 minFromStart+sensorId，判重与前台同口径。
        FlutterForegroundTask.sendDataToMain(BgSync.encode(r.valueMmolL,
            r.trend, r.timestamp, r.minFromStart, r.sensorId));
      } catch (_) {}
    });
    // 后台用省电模式：扫 15 秒、停 45 秒（发射器 1 分钟广播一次，不漏数）。
    // checkPermission:false——后台弹不出授权框，前台点扫描时已授过权。
    await _m!.startLowPowerWatch(checkPermission: false);
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
    await _m?.stopLowPowerWatch();
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
