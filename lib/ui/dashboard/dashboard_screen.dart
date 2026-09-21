import 'package:flutter/material.dart';
import '../data/datasource/local_db.dart';

/// 首页仪表盘
/// 血糖圆环 + 趋势 + 快捷操作
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  double _currentGlucose = 0;
  String _trend = '--';
  Color _statusColor = Colors.grey;
  Map<String, dynamic>? _stats;

  @override
  void initState() {
    super.initState();
    _loadLatest();
  }

  Future<void> _loadLatest() async {
    await AppDatabase.init();
    final rows = await AppDatabase.instance.recentReadings(limit: 1);
    if (rows.isNotEmpty) {
      setState(() {
        _currentGlucose = rows.first['value_mmol_l']?.toDouble() ?? 0;
        _trend = _trendLabel(rows.first['trend'] ?? 0);
        _statusColor = _statusColorFor(rows.first['value_mmol_l']?.toDouble() ?? 0);
      });
    }
    final stats = await AppDatabase.instance.weeklyStats();
    if (mounted) setState(() => _stats = stats);
  }

  String _trendLabel(int trend) {
    switch (trend) {
      case 0: return '→ 平';
      case 1: return '↗ 慢升';
      case 2: return '↗ 快升';
      case 3: return '↘ 慢降';
      case 4: return '↘ 快降';
      default: return '--';
    }
  }

  Color _statusColorFor(double mmolL) {
    if (mmolL < 3.9) return Colors.blue;
    if (mmolL > 10.0) return Colors.red;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('血糖管家')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 血糖圆环
            CircleAvatar(
              radius: 80,
              backgroundColor: _statusColor.withOpacity(0.15),
              child: Center(
                child: Text(
                  _currentGlucose > 0
                      ? _currentGlucose.toStringAsFixed(1)
                      : '--',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: _statusColor,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(_trend, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 4),
            Text(
              _currentGlucose > 0
                  ? '${(_currentGlucose * 18.0182).toStringAsFixed(0)} mg/dL'
                  : '',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 24),

            // 周统计卡片
            if (_stats != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _statCard('TIR', '${_stats!['tir']}%', Colors.green),
                  _statCard('平均', '${(_stats!['avg'] ?? 0).toStringAsFixed(1)} mmol/L', Colors.blue),
                  _statCard('最高', '${_stats!['max']?.toStringAsFixed(1) ?? '--'}', Colors.red),
                  _statCard('最低', '${_stats!['min']?.toStringAsFixed(1) ?? '--'}', Colors.orange),
                ],
              ),
            ],
            const SizedBox(height: 24),

            // 快捷操作
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _actionButton(Icons.bluetooth, '连接血糖仪', () => Navigator.pushNamed(context, '/ble')),
                _actionButton(Icons.add_circle, '手动录入', () => Navigator.pushNamed(context, '/add')),
                _actionButton(Icons.people, '社区', () => Navigator.pushNamed(context, '/community')),
                _actionButton(Icons.smart_toy, 'AI 助手', () => Navigator.pushNamed(context, '/ai-assistant')),
                _actionButton(Icons.medical_services, '泵配对', () => Navigator.pushNamed(context, '/pump-pair')),
                _actionButton(Icons.send, '手动给药', () => Navigator.pushNamed(context, '/manual-bolus')),
                _actionButton(Icons.show_chart, '报告', () => Navigator.pushNamed(context, '/report')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, String value, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
