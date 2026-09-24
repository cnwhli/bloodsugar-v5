import 'package:flutter/material.dart';

import '../../services/cloud_sync.dart';

/// 配对码登录：手表没摄像头，输手机上显示的 6 位数字代替扫码。
/// 圆屏大按钮，满 6 位自动提交；成功后顺手整量同步一次，
/// 手机上的历史立刻到手表。
class PairingCodeScreen extends StatefulWidget {
  const PairingCodeScreen({super.key});

  @override
  State<PairingCodeScreen> createState() => _PairingCodeScreenState();
}

class _PairingCodeScreenState extends State<PairingCodeScreen> {
  String _code = '';
  String _msg = '手机云同步页出码，这里输入';
  bool _busy = false;

  void _tap(String d) {
    if (_busy || _code.length >= 6) return;
    setState(() => _code += d);
    if (_code.length == 6) _submit();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _msg = '登录中…';
    });
    final err = await CloudSync.redeemPairingCode(_code);
    if (!mounted) return;
    if (err == null) {
      String extra = '';
      try {
        final (g, v, t) = await CloudSync.syncAll();
        await CloudSync.subscribeRealtime();
        extra = '，补入血糖 $g / 身体 $v / 记录 $t 条';
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msg = '登录成功$extra';
      });
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _msg = '失败：$err';
        _code = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('配对码登录'),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              6,
              (i) => Container(
                width: 30,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: i < _code.length
                        ? Colors.green
                        : Colors.white24,
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  i < _code.length ? _code[i] : '',
                  style:
                      const TextStyle(fontSize: 24, color: Colors.white),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _msg,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              childAspectRatio: 1.6,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              mainAxisSpacing: 4,
              crossAxisSpacing: 8,
              children: [
                for (final d in [
                  '1',
                  '2',
                  '3',
                  '4',
                  '5',
                  '6',
                  '7',
                  '8',
                  '9'
                ])
                  _key(d, () => _tap(d)),
                _key('清', () => setState(() => _code = '')),
                _key('0', () => _tap('0')),
                _key('⌫', () {
                  if (_code.isNotEmpty) {
                    setState(
                        () => _code = _code.substring(0, _code.length - 1));
                  }
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _key(String t, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(t,
            style: const TextStyle(fontSize: 22, color: Colors.white)),
      ),
    );
  }
}
