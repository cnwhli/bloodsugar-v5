import 'package:flutter/material.dart';

/// 手表端血糖展示小组件（v2：更大触区、更清晰层级）
class WatchGlucoseTile extends StatelessWidget {
  final double value;
  final String trend; // "↑", "↓", "→" 或 区间描述
  final Color statusColor; // 绿/蓝/红 代表不同血糖状态

  const WatchGlucoseTile({
    super.key,
    required this.value,
    required this.trend,
    required this.statusColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,  // 宽度铺满，避免被圆角遮挡
      padding: const EdgeInsets.all(16),  // 增大 padding，触区更大
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withValues(alpha: 0.4), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 大号数值 - 确保至少 48px 高度
          Text(
            value.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 48,      // 增大到 48px
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          // 趋势标签
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              trend,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}