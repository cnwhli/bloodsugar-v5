import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/cloud_sync.dart';

/// 手表扫码登录页：手表打开（圆屏小屏只放取景框+提示），扫手机云同步页
/// 上的二维码 → 同一账号直接登录，不用在手表上输邮箱密码。
///
/// 安全：二维码只显示 60 秒（和登录 token 同寿命，截屏过期即废），
/// 手机点一下重新生成。
class WatchLoginScanScreen extends StatefulWidget {
  const WatchLoginScanScreen({super.key});

  @override
  State<WatchLoginScanScreen> createState() => _WatchLoginScanScreenState();
}

class _WatchLoginScanScreenState extends State<WatchLoginScanScreen> {
  final _ctl = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  String _msg = '把手机上的二维码放进框里';
  bool _done = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_done) return;
    final raw = cap.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    _done = true; // 先锁住，扫码器 noDuplicates 也可能连发
    setState(() => _msg = '登录中…');
    final err = await CloudSync.signInWithQrPayload(raw);
    if (!mounted) return;
    if (err == null) {
      // 成功：顺手整量同步一次，手机上的历史立刻到手表
      String extra = '';
      try {
        final (g, v, t) = await CloudSync.syncAll();
        await CloudSync.subscribeRealtime();
        extra = '，补入血糖 $g / 身体 $v / 记录 $t 条';
      } catch (_) {}
      if (!mounted) return;
      setState(() => _msg = '登录成功$extra');
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        _msg = '失败：$err，点一下重扫';
        _done = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫码登录'),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (_done) return;
                setState(() => _msg = '把手机上的二维码放进框里');
              },
              child: MobileScanner(
                controller: _ctl,
                onDetect: _onDetect,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
