import 'package:flutter/material.dart';
import '../chat/ai_agent_service.dart';

// RadioListTile 在 Flutter 3.47 已废弃 groupValue/onChanged，改用 RadioGroup

/// AI 设置页（我的 → AI 设置）
///
/// Hermes 接入（推荐，数据不出内网）：
/// 1. 电脑上跑 `hermes proxy`（OpenAI 兼容代理，默认端口看终端输出）
/// 2. 手机和电脑连同一 WiFi，baseUrl 填 http://电脑IP:端口
/// 3. model 填 default（走 Hermes 当前模型），内网一般无需 API Key
///
/// OpenClaw 同理：填它的 OpenAI 兼容端点地址即可。
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  AiAgentConfig _cfg = AiAgentConfig();
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    AiAgentConfig.load().then((cfg) {
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _urlCtrl.text = cfg.baseUrl;
        _modelCtrl.text = cfg.model;
        _keyCtrl.text = cfg.apiKey;
      });
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _cfg.baseUrl = _urlCtrl.text.trim();
    _cfg.model = _modelCtrl.text.trim().isEmpty ? 'default' : _modelCtrl.text.trim();
    _cfg.apiKey = _keyCtrl.text.trim();
    _cfg.enabled = _cfg.baseUrl.isNotEmpty;
    await _cfg.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_cfg.enabled ? '已启用（${_cfg.providerLabel}）' : '已关闭云端，本地模式')),
    );
    setState(() {});
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final tmp = AiAgentConfig(
      enabled: true,
      provider: _cfg.provider,
      baseUrl: _urlCtrl.text.trim(),
      model: _modelCtrl.text.trim().isEmpty ? 'default' : _modelCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
    );
    final r = await AiAgentService().testConnection(tmp);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('提供方', style: TextStyle(fontWeight: FontWeight.bold)),
            RadioGroup<AiProvider>(
              groupValue: _cfg.provider,
              onChanged: (v) =>
                  setState(() => _cfg.provider = v ?? _cfg.provider),
              child: Column(
                children: AiProvider.values
                    .map((p) => RadioListTile<AiProvider>(
                          title: Text(p.label),
                          value: p,
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '网关地址',
                hintText: '如 http://192.168.0.100:11438',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                labelText: '模型（默认 default）',
                hintText: 'default / claude-opus-5 / gpt-4o',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key（可选，内网可空）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _save,
                    child: const Text('保存并启用'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _testing ? null : _test,
                    child: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                ),
              ],
            ),
            if (_testResult != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_testResult!),
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              '说明：默认走免费在线 AI，开箱即用（需联网，不出国、无需配置）。\n'
              '也可切换 Hermes/OpenClaw，地址和 Key 只存本机，卸载即删；内网使用数据不出家门。\n'
              '食物打卡（"吃了一碗螺蛳粉"）本地先算 GI 和升糖预测，联网后 AI 再给个性化建议。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
