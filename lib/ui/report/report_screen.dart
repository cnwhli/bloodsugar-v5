import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/datasource/local_db.dart';

/// 血糖报告页：周统计 + 最近记录列表 + CSV 导出
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await AppDatabase.init();
      final stats = await AppDatabase.instance.weeklyStats();
      final recent =
          await AppDatabase.instance.recentReadings(limit: 50);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _recent = recent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('加载失败：$e')));
    }
  }

  Future<void> _exportCsv() async {
    if (_recent.isEmpty) return;
    final buf = StringBuffer('time,mmol_L,mg_dL,trend,brand,source,notes\n');
    for (final r in _recent.reversed) {
      buf.write(
          '${r['created_at']},${r['value_mmol_l']},${r['value_mg_dl']},${r['trend']},${r['brand']},${r['source']},${r['notes'] ?? ''}\n');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('CSV 已复制到剪贴板，可粘贴发给医生')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('血糖报告'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '导出 CSV',
            onPressed: _exportCsv,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_stats != null &&
                      (_stats!['total'] as int? ?? 0) > 0) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _statCard('TIR', '${_stats!['tir']}%',
                            Colors.green),
                        _statCard(
                            '平均',
                            '${((_stats!['avg'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}',
                            Colors.blue),
                        _statCard(
                            '最高',
                            '${((_stats!['max'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}',
                            Colors.red),
                        _statCard(
                            '最低',
                            '${((_stats!['min'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}',
                            Colors.orange),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '近 7 天共 ${_stats!['total']} 条（mmol/L）',
                      style: const TextStyle(color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Text('最近记录',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  if (_recent.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('暂无记录，去首页录入或连接血糖仪',
                            style: TextStyle(color: Colors.grey)),
                      ),
                    ),
                  ..._recent.map((r) => Card(
                        child: ListTile(
                          title: Text(
                            '${(r['value_mmol_l'] as num).toStringAsFixed(1)} mmol/L',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                              '${r['brand'] ?? ''} · ${r['source'] ?? ''} · ${(r['created_at'] ?? '').toString().substring(0, 16)}'),
                          trailing: _trendIcon(
                              (r['trend'] as num?)?.toInt() ?? 0),
                        ),
                      )),
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
            Text(label,
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            Text(value,
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: color)),
          ],
        ),
      ),
    );
  }

  Widget _trendIcon(int trend) {
    switch (trend) {
      case 1:
      case 2:
        return const Icon(Icons.arrow_upward, color: Colors.red);
      case 3:
      case 4:
        return const Icon(Icons.arrow_downward, color: Colors.blue);
      default:
        return const Icon(Icons.check_circle, color: Colors.green);
    }
  }
}
