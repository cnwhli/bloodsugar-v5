import 'package:flutter/material.dart';

import '../../services/cloud_sync.dart';
import 'pairing_code_screen.dart';

/// 云同步页：Supabase 账号登录 + 一键同步 + 换设备恢复。
///
/// key 只存本机安全存储，不进代码不进仓库。同一账号在手机/手表登录，
/// 双方上传的数据经 Realtime 秒级互通（订阅在首页/手表页里接）。
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key});

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  String _msg = '';
  bool _busy = false;
  bool _ready = false;
  bool _loggedIn = false;
  String? _pairCode; // 手机出的 6 位配对码（手表输码登录，点码隐藏）

  @override
  void initState() {
    super.initState();
    _ready = CloudSync.isReady;
    _loggedIn = CloudSync.loggedIn;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _emailCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() fn, String okText,
      {bool refreshLogin = false}) async {
    setState(() {
      _busy = true;
      _msg = '';
    });
    try {
      final err = await fn();
      if (!mounted) return;
      setState(() {
        _msg = err ?? okText;
        if (refreshLogin) _loggedIn = CloudSync.loggedIn;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _msg = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云同步')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('手机/手表用同一账号登录，双方数据秒级互通，换设备登录即恢复。',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          if (!_ready) ...[
            // 包自带项目连接信息时跳过此步，直接登录（手表再也不用敲 URL/key）。
            if (!CloudSync.hasBuiltIn) ...[
              const Text('第 1 步：填 Supabase 项目（只填一次，存本机）',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Project URL',
                  hintText: 'https://xxx.supabase.co',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyCtrl,
                decoration: const InputDecoration(
                  labelText: 'anon public key',
                  hintText: 'Settings → API → anon public',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                          () async {
                            final ok = await CloudSync.configure(
                                _urlCtrl.text, _keyCtrl.text);
                            if (mounted && ok) {
                              setState(() => _ready = true);
                            }
                            return ok ? '连接成功，登录账号即可同步' : '连接失败：检查URL/key/网络';
                          },
                          '连接成功',
                        ),
                child: const Text('连接'),
              ),
            ] else
              const Card(
                child: ListTile(
                  leading: Icon(Icons.check_circle, color: Colors.green),
                  title: Text('项目已内置，登录账号即可同步'),
                ),
              ),
          ] else ...[
            Card(
              child: ListTile(
                leading: Icon(
                    _loggedIn ? Icons.cloud_done : Icons.cloud_off,
                    color: _loggedIn ? Colors.green : Colors.grey),
                title: Text(_loggedIn ? '已登录（可同步）' : '未登录（本机模式）'),
                subtitle: Text(_loggedIn
                    ? '新数据自动上传，换设备点“从云端恢复”'
                    : '登录后手机/手表数据互通'),
              ),
            ),
            const SizedBox(height: 8),
            if (!_loggedIn) ...[
              // 手表没摄像头不能扫码：手表输手机上显示的 6 位配对码登录。
              // （圆屏小屏优先配对码；扫码入口留给有摄像头的设备。）
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final ok = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  const PairingCodeScreen()),
                        );
                        if (ok == true && mounted) {
                          setState(() => _loggedIn = true);
                        }
                      },
                icon: const Icon(Icons.pin),
                label: const Text('配对码登录（手表输6位数字）'),
              ),
              const SizedBox(height: 8),
              const Row(
                children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('或手动输入',
                        style:
                            TextStyle(color: Colors.grey, fontSize: 12)),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pwdCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => CloudSync.signIn(
                                  _emailCtrl.text.trim(), _pwdCtrl.text),
                              '登录成功',
                              refreshLogin: true),
                      child: const Text('登录'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => CloudSync.signUp(
                                  _emailCtrl.text.trim(), _pwdCtrl.text),
                              '注册成功（可能需邮箱确认）',
                              refreshLogin: true),
                      child: const Text('注册'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          final (g, v, t) = await CloudSync.syncAll();
                          // 下拉后顺手订阅 Realtime，后续秒级互通
                          await CloudSync.subscribeRealtime();
                          return '补入：血糖 $g 条 / 身体 $v 条 / 记录 $t 条（重复自动跳过）';
                        }, '同步完成'),
                icon: const Icon(Icons.sync),
                label: const Text('立即同步 / 从云端恢复'),
              ),
              const SizedBox(height: 8),
              // 手机出 6 位配对码（5 分钟有效，一次即焚）：手表没摄像头，
              // 云同步页输码即登录同一账号——圆屏输 6 个数字最现实。
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() {
                          _busy = true;
                          _msg = '';
                          _pairCode = null;
                        });
                        try {
                          final c =
                              await CloudSync.createPairingCode();
                          if (!mounted) return;
                          setState(() {
                            _pairCode = c;
                            _msg = c == null
                                ? '生成失败：先登录账号（配对码和登录同寿命）'
                                : '手表打开 云同步→配对码登录，输这 6 位（5分钟有效，一次即焚）';
                          });
                        } catch (e) {
                          if (!mounted) return;
                          setState(() => _msg = '$e');
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                icon: const Icon(Icons.pin),
                label: const Text('手表配对码（6位数字）'),
              ),
              if (_pairCode != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => setState(() => _pairCode = null),
                  child: Center(
                    child: Text(
                      _pairCode!,
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 12,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                await CloudSync.signOut();
                                if (mounted) {
                                  setState(() => _loggedIn = false);
                                }
                                return '已退出（本机数据保留）';
                              }, '已退出', refreshLogin: true),
                      child: const Text('退出登录'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                await CloudSync.clearConfig();
                                if (mounted) {
                                  setState(() {
                                    _ready = false;
                                    _loggedIn = false;
                                  });
                                }
                                return '已清除配置';
                              }, '已清除'),
                      child: const Text('换项目/清配置',
                          style: TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
              ),
            ],
          ],
          if (_msg.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_msg, style: const TextStyle(color: Colors.orange)),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
