import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bloodsugar_v5/domain/bluetooth/cgm_protocol.dart';
import '../watch/multi_watch_arch.dart';

/// 手表端血糖页面
/// 支持圆形/方形屏幕自适应
///
/// 数据流：Supabase Realtime → WatchSyncService → 实时更新
/// 预警：低血糖 (<3.9) 蓝屏三短震 / 高血糖 (>10) 红屏两长震

class WatchGlucosePage extends StatefulWidget {
  final WatchShape shape; // 屏幕形状（圆形/方形）
  final String userId;

  const WatchGlucosePage({
    super.key,
    this.shape = WatchShape.rectangular,
    required this.userId,
  });

  @override
  State<WatchGlucosePage> createState() => _WatchGlucosePageState();
}

class _WatchGlucosePageState extends State<WatchGlucosePage> {
  double _mmolL = 0;
  int _trend = 0;
  String _brand = '';
  DateTime _updatedAt = DateTime.now();
  bool _lowAlert = false;
  bool _highAlert = false;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initSupabase();
  }

  Future<void> _initSupabase() async {
    // Supabase Realtime 订阅
    // Supabase.instance.client
    //     .channel('glucose:${widget.userId}')
    //     .onPostgresChanges(
    //       event: 'UPDATE',
    //       schema: 'public',
    //       table: 'glucose_readings',
    //       callback: (payload) {
    //         final newReading = GlucoseReading.fromJson(payload['new']);
    //         _checkAlerts(newReading);
    //       },
    //     )
    //     .subscribe();

    // 模拟数据（开发用）
    await Future.delayed(const Duration(seconds: 1));
    setState(() {
      _mmolL = 6.2;
      _trend = 1;
      _brand = 'Libre 2';
      _updatedAt = DateTime.now();
      _loading = false;
    });
  }

  void _checkAlerts(GlucoseReading reading) {
    final isLow = WatchApp.isLow(reading.valueMmolL);
    final isHigh = WatchApp.isHigh(reading.valueMmolL);

    if (isLow || isHigh) {
      _triggerAlert(isLow: isLow, isHigh: isHigh);
    }

    setState(() {
      _mmolL = reading.valueMmolL;
      _trend = reading.trend;
      _brand = reading.brand.displayName;
      _updatedAt = reading.timestamp;
      _lowAlert = isLow;
      _highAlert = isHigh;
    });
  }

  Future<void> _triggerAlert({required bool isLow, required bool isHigh}) async {
    // 震动模式
    const lowPattern = [500, 200, 500, 200, 500]; // 三短震
    const highPattern = [1000, 200, 1000]; // 两长震

    if (isLow) {
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 500));
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 200));
      HapticFeedback.heavyImpact();
    } else if (isHigh) {
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 1000));
      HapticFeedback.mediumImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _lowAlert
        ? Colors.blue
        : _highAlert
            ? Colors.red
            : Colors.green;

    return WatchAdaptiveLayout(
      shape: widget.shape,
      child: _buildContent(statusColor: statusColor),
    );
  }

  Widget _buildContent({required Color statusColor}) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error.isNotEmpty) {
      return Center(child: Text('错误: $_error'));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 预警横幅
        if (_lowAlert || _highAlert) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _lowAlert ? Colors.blue : Colors.red,
              borderRadius: BorderRadius.circular(widget.shape.isCircular ? 16 : 8),
            ),
            child: Text(
              _lowAlert ? '⚠️ 低血糖' : '⚠️ 高血糖',
              style: const TextStyle(
                color: Colors.white,
                fontSize: widget.shape.isCircular ? 14 : 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        // 血糖值
        Text(
          _mmolL > 0 ? _mmolL.toStringAsFixed(1) : '--',
          style: TextStyle(
            fontSize: widget.shape.isCircular ? 36 : 56,
            fontWeight: FontWeight.bold,
            color: statusColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _mmolL > 0
              ? '${(_mmolL * 18.0182).toStringAsFixed(0)} mg/dL'
              : '',
          style: const TextStyle(
            fontSize: widget.shape.isCircular ? 12 : 16,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _trendLabel(_trend),
          style: TextStyle(
            fontSize: widget.shape.isCircular ? 16 : 18,
            color: statusColor,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _brand,
          style: const TextStyle(
            fontSize: widget.shape.isCircular ? 10 : 12,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${_updatedAt.hour}:${_updatedAt.minute}',
          style: const TextStyle(
            fontSize: widget.shape.isCircular ? 10 : 12,
            color: Colors.grey,
          ),
        ),
      ],
    );
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
}