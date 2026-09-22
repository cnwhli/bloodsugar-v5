import 'package:flutter/material.dart';
import '../../services/alert_service.dart';

/// 阈值 + 报警设置页（我的 → 报警设置 / 首页右上角铃铛）
class AlertSettingsScreen extends StatefulWidget {
  const AlertSettingsScreen({super.key});

  @override
  State<AlertSettingsScreen> createState() => _AlertSettingsScreenState();
}

class _AlertSettingsScreenState extends State<AlertSettingsScreen> {
  AlertSettings _s = AlertSettings();
  final _highCtrl = TextEditingController();
  final _lowCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    AlertSettings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _s = s;
        _highCtrl.text = s.highThreshold.toStringAsFixed(1);
        _lowCtrl.text = s.lowThreshold.toStringAsFixed(1);
      });
    });
  }

  @override
  void dispose() {
    _highCtrl.dispose();
    _lowCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final h = double.tryParse(_highCtrl.text.trim());
    final l = double.tryParse(_lowCtrl.text.trim());
    if (h == null || l == null || h <= l || h > 30 || l < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('阈值无效：需 1–30 且高 > 低')),
      );
      return;
    }
    _s.highThreshold = h;
    _s.lowThreshold = l;
    await _s.save();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('报警设置已保存')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('报警设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _highCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(
                            decimal: true),
                    decoration: const InputDecoration(
                      labelText: '高血糖阈值（mmol/L）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _lowCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(
                            decimal: true),
                    decoration: const InputDecoration(
                      labelText: '低血糖阈值（mmol/L）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('高血糖报警方式',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...AlertMode.values.map((m) => RadioListTile<AlertMode>(
                  title: Text(m.label),
                  value: m,
                  groupValue: _s.highAlert,
                  onChanged: (v) =>
                      setState(() => _s.highAlert = v ?? _s.highAlert),
                )),
            const SizedBox(height: 8),
            const Text('低血糖报警方式',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ...AlertMode.values.map((m) => RadioListTile<AlertMode>(
                  title: Text(m.label),
                  value: m,
                  groupValue: _s.lowAlert,
                  onChanged: (v) =>
                      setState(() => _s.lowAlert = v ?? _s.lowAlert),
                )),
            const SizedBox(height: 16),
            ElevatedButton(
                onPressed: _save, child: const Text('保存')),
            const SizedBox(height: 8),
            const Text(
              '同方向 5 分钟内只响一次，避免打扰。\n曲线图上的红蓝阈值线跟随这里的设置变化。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
