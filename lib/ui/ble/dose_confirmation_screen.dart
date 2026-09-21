import 'package:flutter/material.dart';
import '../../domain/bluetooth/pump_protocol.dart';

/// 半闭环剂量确认页面
/// 安全边界：App 计算 → 弹窗确认 → 用户手动执行
class DoseConfirmationScreen extends StatelessWidget {
  final DoseSuggestion suggestion;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const DoseConfirmationScreen({
    super.key,
    required this.suggestion,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            suggestion.safe ? Icons.check_circle : Icons.warning,
            color: suggestion.safe ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Text(suggestion.safe ? '建议剂量' : '注意'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${suggestion.bolusUnits} 单位',
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text('计算依据：${suggestion.reason}'),
          if (suggestion.safetyNote.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              suggestion.safetyNote,
              style: const TextStyle(color: Colors.orange),
            ),
          ],
          const Divider(),
          const Text(
            '⚠️ 半闭环提醒：App 仅给出建议，\n'
            '请在泵上手动确认给药。App 不会自动注射。',
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: suggestion.safe ? onConfirm : null,
          child: const Text('确认给药'),
        ),
      ],
    );
  }
}
