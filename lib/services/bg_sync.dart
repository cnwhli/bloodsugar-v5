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
}

/// 顶层回调（插件要求必须是顶层或静态函数，不能是闭包/成员方法）
void bgTaskCallback(Object data) {
  BgSync.notify('$data');
}
