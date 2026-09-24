/// 对话记一笔：从一句话里识别饮食/用药/打针/运动/心率，生成待确认草稿。
/// 纯本地正则，不联网。识别到就返回草稿列表，由聊天页弹窗让用户确认后落库。
library;

/// 一条待确认记录
class DraftRecord {
  /// treatments 表用：insulin / medication / food / exercise / note
  /// vitals 表用：heart_rate / steps（[isVital]=true）
  final String kind;
  final bool isVital;
  final String label; // 给用户看的一句话，如"胰岛素 门冬 6U"
  final String? detail;
  final double? amount;
  final String? unit;
  final String extra;

  const DraftRecord({
    required this.kind,
    required this.label,
    this.isVital = false,
    this.detail,
    this.amount,
    this.unit,
    this.extra = 'AI对话',
  });
}

/// 从用户一句话里提取记账意图，可多条（如"吃了两碗米饭，打了6U"出两条）。
List<DraftRecord> parseLogIntent(String text) {
  final out = <DraftRecord>[];
  final q = text.replaceAll(' ', '');

  // ---- 胰岛素：6U / 6单位 / 打了6个单位 ----
  final insRe = RegExp(r'(?:打了?|注射)?(\d+(?:\.\d+)?)\s*(U|u|单位)');
  final insM = insRe.firstMatch(q);
  if (insM != null) {
    final v = double.tryParse(insM.group(1) ?? '') ?? 0;
    if (v > 0 && v <= 100) {
      var name = '胰岛素';
      for (final n in ['门冬', '甘精', '地特', '德谷', '赖脯', '谷赖', '诺和', '速秀', '长秀']) {
        if (q.contains(n)) {
          name = n;
          break;
        }
      }
      out.add(DraftRecord(
        kind: 'insulin',
        label: name == '胰岛素'
            ? '胰岛素 ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}U'
            : '$name ${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}U',
        detail: name,
        amount: v,
        unit: 'U',
      ));
    }
  }

  // ---- 心率：心跳95 / 心率88 ----
  final hrM = RegExp(r'(?:心跳|心率|脉搏)(\D{0,4})(\d{2,3})').firstMatch(q);
  if (hrM != null) {
    final v = double.tryParse(hrM.group(2) ?? '') ?? 0;
    if (v >= 30 && v <= 220) {
      out.add(DraftRecord(
        kind: 'heart_rate',
        isVital: true,
        label: '心率 ${v.toInt()} bpm',
        amount: v,
        unit: 'bpm',
      ));
    }
  }

  // ---- 步数：走了8000步 / 步数5000 ----
  final stM = RegExp(r'(?:走了?|步数)(\D{0,4})(\d{3,6})步?').firstMatch(q);
  if (stM != null) {
    final v = double.tryParse(stM.group(2) ?? '') ?? 0;
    if (v > 0 && v <= 100000) {
      out.add(DraftRecord(
        kind: 'steps',
        isVital: true,
        label: '步数 ${v.toInt()} 步',
        amount: v,
        unit: '步',
      ));
    }
  }

  // ---- 运动：跑步30分钟 / 散步20分钟 ----
  final exM = RegExp(r'(跑步|散步|快走|骑车|游泳|运动|锻炼)(\D{0,6})(\d{1,3})分钟').firstMatch(q);
  if (exM != null) {
    final v = double.tryParse(exM.group(3) ?? '') ?? 0;
    if (v > 0 && v <= 600) {
      out.add(DraftRecord(
        kind: 'exercise',
        label: '运动 ${exM.group(1)} ${v.toInt()}分钟',
        detail: exM.group(1),
        amount: v,
        unit: '分钟',
      ));
    }
  }

  // ---- 口服药：吃了二甲双胍 / 服药 ----
  const meds = ['二甲双胍', '格列美脲', '阿卡波糖', '达格列净', '恩格列净', '西格列汀', '瑞格列奈', '吡格列酮'];
  for (final m in meds) {
    if (q.contains(m)) {
      out.add(DraftRecord(kind: 'medication', label: '口服药 $m', detail: m, unit: '片'));
      break;
    }
  }

  // ---- 饮食：吃了两碗米饭 / 喝了一杯奶茶 / 吃个苹果 ----
  // 有"吃/喝"字，且不是药名，才算饮食
  if ((q.contains('吃') || q.contains('喝')) && out.every((d) => d.kind != 'medication')) {
    final foodM = RegExp(r'[吃喝]了?(.{1,12}?)(?:，|。|、|；|；|$|，打|打\d)').firstMatch(q);
    var food = foodM?.group(1)?.trim() ?? '';
    // 去掉"了/过"尾巴
    food = food.replaceAll(RegExp(r'^(了|过)+'), '').trim();
    if (food.isNotEmpty && food.length <= 12 && !food.contains('胰岛素') && !food.contains('单位')) {
      // 数量词：两碗/2碗/一个/半份
      var qty = '';
      final qM = RegExp(r'([两二三四五六七八九十\d半]+[碗个杯份块片根包袋瓶]|半份?)').firstMatch(food);
      if (qM != null) qty = qM.group(1) ?? '';
      out.add(DraftRecord(
        kind: 'food',
        label: '饮食 $food${qty.isNotEmpty ? '' : ''}',
        detail: food,
        unit: '份',
      ));
    }
  }
  return out;
}
