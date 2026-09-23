/// 用药/打针/饮食/运动记录的类型标签 + 展示 + 剂量校验（纯 Dart，可单测）
///
/// 安全边界与手动给药页一致：胰岛素单次上限 12U。
/// 记录≠给药：这里只记"打了什么"，不发任何指令到泵。
library;

/// 记录类型 → 中文名（type 存英文，显示中文）
String treatmentTypeLabel(String type) {
  switch (type) {
    case 'insulin':
      return '胰岛素';
    case 'medication':
      return '口服药';
    case 'food':
      return '饮食';
    case 'exercise':
      return '运动';
    case 'note':
      return '备注';
    default:
      return type;
  }
}

/// 列表展示文案：明细 + 剂量单位 + 注射部位/备注
String formatTreatment({
  required String type,
  String? detail,
  double? amount,
  String? unit,
  String? extra,
}) {
  // 胰岛素习惯写法"门冬 6U · 腹部"：明细和剂量连写，其余用 · 隔
  var head = detail ?? '';
  if (amount != null) {
    head = head.isEmpty
        ? '${_fmtNum(amount)}${unit ?? ''}'
        : '$head ${_fmtNum(amount)}${unit ?? ''}';
  }
  final parts = <String>[];
  if (head.isNotEmpty) parts.add(head);
  if (extra != null && extra.isNotEmpty) parts.add(extra);
  if (parts.isEmpty) return treatmentTypeLabel(type);
  return parts.join(' · ');
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? '${v.toInt()}' : '$v';

/// 胰岛素剂量校验：合法返回 null，否则返回错误文案
String? checkInsulinDose(double units) {
  if (units <= 0) return '剂量必须大于 0';
  if (units > 12) return '单次最多 12U，超量请分次记录';
  return null;
}
