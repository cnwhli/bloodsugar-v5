import 'package:flutter/material.dart';
import '../../domain/bluetooth/cgm_protocol.dart';
import '../../data/datasource/local_db.dart';

/// BLE 扫描 + 连接页面（完整流程）
class BleScannerScreen extends StatefulWidget {
  const BleScannerScreen({super.key});

  @override
  State<BleScannerScreen> createState() => _BleScannerScreenState();
}

class _BleScannerScreenState extends State<BleScannerScreen> {
  final _manager = BleCgmManager();
  List<GlucoseReading> _readings = [];
  String _statusText = '就绪';
  List<String> _log = [];

  @override
  void initState() {
    super.initState();
    AppDatabase.init();
    _manager.stateStream.listen((state) {
      setState(() => _statusText = state.toString().split('.').last);
      _log.add('状态: $_statusText');
    });
    _manager.readingStream.listen((reading) async {
      setState(() {
        _readings.insert(0, reading);
        if (_readings.length > 100) _readings.removeLast();
      });
      await AppDatabase.instance.insertReading(reading);
      _log.add('${reading.valueMmolL.toStringAsFixed(1)} mmol/L · ${reading.brand.displayName}');
    });
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接血糖仪'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Center(
              child: Text(
                _statusText,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 状态栏
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[200],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('状态: $_statusText', style: const TextStyle(fontSize: 14)),
                Text('已读: ${_readings.length} 条', style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
          // 操作按钮
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _manager.startScan(),
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('扫描'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _manager.disconnect(),
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: const Text('断开'),
                  ),
                ),
              ],
            ),
          ),
          // 最近读数
          Expanded(
            child: ListView.builder(
              itemCount: _readings.length > 20 ? 20 : _readings.length,
              itemBuilder: (context, i) {
                final r = _readings[i];
                return ListTile(
                  title: Text(
                    '${r.valueMmolL.toStringAsFixed(1)} mmol/L',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '${r.brand.displayName} · ${r.timestamp.toString().substring(11, 19)}',
                  ),
                  trailing: Icon(
                    r.status == 'low'
                        ? Icons.arrow_downward
                        : r.status == 'high'
                            ? Icons.arrow_upward
                            : Icons.check_circle,
                    color: r.status == 'low'
                        ? Colors.blue
                        : r.status == 'high'
                            ? Colors.red
                            : Colors.green,
                  ),
                );
              },
            ),
          ),
          // 日志（底部）
          Container(
            height: 80,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              border: Border(top: BorderSide(color: Colors.grey[300]!)),
            ),
            child: ListView(
              children: _log
                  .sublist(_log.length > 10 ? _log.length - 10 : 0)
                  .map((l) => Text(l, style: const TextStyle(fontSize: 11)))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}
