import 'package:flutter/material.dart';
import 'watch_app.dart';

/// 手表端血糖展示小组件
class WatchGlucoseTile extends StatelessWidget {
  final double value;
  final String trend;
  final Color statusColor;

  const WatchGlucoseTile({
    super.key,
    required this.value,
    required this.trend,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${value.toStringAsFixed(1)}',
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.bold,
              color: statusColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            trend,
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }
}
