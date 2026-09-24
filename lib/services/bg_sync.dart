import 'dart:async';

/// 后台 isolate → 主 isolate 通知桥（flutter_foreground_task 通道）。
///
/// 病根回顾：后台前台服务在独立 isolate 里收数、直接入库，但主 isolate
/// 的各页面订阅的是主 isolate 的 readingStream——后台收的数主 isolate
/// 根本不知道，所以"退后台就断、一点开/一下拉又有"（库里有，UI 没刷）。
/// 修法：后台每收一条就 sendDataToMain，主 isolate 经顶层回调落到本桥，
/// 各页面订阅本桥自动刷新。
class BgSync {
  static final _c = StreamController<String>.broadcast();

  static Stream<String> get stream => _c.stream;

  static void notify(String msg) {
    if (!_c.isClosed) _c.add(msg);
  }

  /// v3 格式：valueMmol|trend|isoTime|seq|sensorId（seq = 发射器分钟序号，
  /// sensorId = 广播名后6位配对码；无则空）。
  /// seq 必须透过来：之前只传前 3 段，主 isolate 重建的 reading 没有
  /// minFromStart，只能按 45 秒同值回退去重——前后台双写的同一分钟点
  /// 时间戳差几秒、数值相同，去重失效，列表出现"6.3×4条同秒"。
  /// sensorId 同理：换发射器后序号从 0 重计，主 isolate 重建的 reading
  /// 必须带发射器身份，否则按（序号, 发射器）联合去重不完整。
  static String encode(
          double mmolL, int trend, DateTime ts, int? seq, String sensorId) =>
      '$mmolL|$trend|${ts.toIso8601String()}|${seq ?? ''}|$sensorId';

  /// 老版本只有前 3/4 段，decode 兼容（seq/sensorId 按无处理）。
  static ({double v, int trend, DateTime ts, int? seq, String sensorId})?
      decode(String msg) {
    try {
      final parts = msg.split('|');
      if (parts.length < 3) return null;
      final v = double.tryParse(parts[0]) ?? 0;
      if (v <= 0) return null;
      return (
        v: v,
        trend: int.tryParse(parts[1]) ?? 0,
        ts: DateTime.tryParse(parts[2]) ?? DateTime.now(),
        seq: parts.length >= 4 ? int.tryParse(parts[3]) : null,
        sensorId: parts.length >= 5 ? parts[4] : '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// 顶层回调（插件要求必须是顶层或静态函数，不能是闭包/成员方法）
void bgTaskCallback(Object data) {
  BgSync.notify('$data');
}
